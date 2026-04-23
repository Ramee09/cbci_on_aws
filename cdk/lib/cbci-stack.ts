import * as cdk      from 'aws-cdk-lib';
import * as eks      from 'aws-cdk-lib/aws-eks';
import * as iam      from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export interface CbciStackProps extends cdk.StackProps {
  cluster:      eks.Cluster;
  fileSystemId: string;
}

// ── Helm chart + image versions (all pinned per CLAUDE.md) ───────────────────
const CBCI_CHART_VERSION = '3.15155.0+c4c87a7d6f57';  // bump to upgrade CBCI
const CBCI_IMAGE_VERSION = '2.555.1.36485';
const OC_HOSTNAME        = 'cjoc.myhomettbros.com';
const ACM_CERT_ARN       = 'arn:aws:acm:us-east-1:835090871306:certificate/8d0bab7f-cd88-45de-911f-1574b1f3db60';
const GITHUB_REPO        = 'https://github.com/Ramee09/cbci_on_aws.git';

export class CbciStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CbciStackProps) {
    super(scope, id, props);

    const { cluster } = props;

    // ── EFS StorageClass — dynamic AP provisioning via EFS CSI driver ────────
    // Uses KubernetesManifest constructor (not cluster.addManifest) so this
    // construct is scoped to CbciStack, avoiding EksStack→StorageStack cycle.
    new eks.KubernetesManifest(this, 'EfsStorageClass', {
      cluster,
      manifest: [{
        apiVersion: 'storage.k8s.io/v1',
        kind:       'StorageClass',
        metadata: {
          name:        'efs-ap',
          annotations: { 'storageclass.kubernetes.io/is-default-class': 'false' },
        },
        provisioner: 'efs.csi.aws.com',
        parameters: {
          provisioningMode:      'efs-ap',
          fileSystemId:          props.fileSystemId,
          directoryPerms:        '700',
          gidRangeStart:         '1000',
          gidRangeEnd:           '2000',
          basePath:              '/jenkins',
          subPathPattern:        '${.PVC.name}',
          ensureUniqueDirectory: 'true',
        },
        reclaimPolicy:        'Retain',
        volumeBindingMode:    'Immediate',
        allowVolumeExpansion: true,
      }],
    });

    // ── cloudbees namespace ───────────────────────────────────────────────────
    new eks.KubernetesManifest(this, 'CloudbeesNamespace', {
      cluster,
      manifest: [{
        apiVersion: 'v1',
        kind:       'Namespace',
        metadata:   { name: 'cloudbees' },
      }],
    });

    // ── Pull admin password from Secrets Manager, inject as k8s secret ───────
    const adminSecret = secretsmanager.Secret.fromSecretNameV2(
      this, 'JenkinsAdminSecret', 'cbci-lab/jenkins-admin-password',
    );

    new eks.KubernetesManifest(this, 'JenkinsAdminK8sSecret', {
      cluster,
      manifest: [{
        apiVersion: 'v1',
        kind:       'Secret',
        metadata:   { name: 'jenkins-admin-secret', namespace: 'cloudbees' },
        type:       'Opaque',
        stringData: {
          // Resolved at synth time — stored encrypted in CloudFormation
          password: adminSecret.secretValue.unsafeUnwrap(),
        },
      }],
    });

    // ── Hazelcast RBAC (allows controller pods to list peers for discovery) ───
    new eks.KubernetesManifest(this, 'HazelcastRbac', {
      cluster,
      manifest: this.hazelcastRbac(),
    });

    // ── HA gossip NetworkPolicies (Hazelcast TCP 5701 between replicas) ───────
    new eks.KubernetesManifest(this, 'HaGossipPolicies', {
      cluster,
      manifest: this.haGossipPolicies(),
    });

    // ── CBCI Helm chart ───────────────────────────────────────────────────────
    new eks.HelmChart(this, 'Cbci', {
      cluster,
      chart:      'cloudbees-core',
      repository: 'https://charts.cloudbees.com/public/cloudbees',
      namespace:  'cloudbees',
      release:    'cbci',
      version:    CBCI_CHART_VERSION,
      values: {
        OperationsCenter: {
          Platform: 'standard',

          // SCM Retriever: OC pulls casc/ from GitHub, hot-reloads on change
          CasC: {
            Enabled: true,
            Retriever: {
              Enabled:            true,
              scmRepo:            GITHUB_REPO,
              scmBranch:          'main',
              scmBundlePath:      'casc/oc-bundle',
              scmPollingInterval: 'PT1M',
              githubWebhooksEnabled: 'false',
            },
          },

          JavaOpts: [
            `-Dcom.cloudbees.networking.protocol=https`,
            `-Dcom.cloudbees.networking.hostname=${OC_HOSTNAME}`,
            `-Dcom.cloudbees.networking.useSubdomain=false`,
          ].join(' '),

          ContainerEnv: [{
            name: 'JENKINS_ADMIN_PASSWORD',
            valueFrom: {
              secretKeyRef: { name: 'jenkins-admin-secret', key: 'password' },
            },
          }],

          NodeSelector: { role: 'system' },

          Resources: {
            Requests: { Cpu: '1',  Memory: '2G' },
            Limits:   { Cpu: '2',  Memory: '4G' },
          },

          ServiceType: 'ClusterIP',
          HostName:    null,

          Ingress: {
            Class: 'alb',
            Annotations: {
              'alb.ingress.kubernetes.io/scheme':       'internet-facing',
              'alb.ingress.kubernetes.io/target-type':  'ip',
              'alb.ingress.kubernetes.io/listen-ports': '[{"HTTP":80},{"HTTPS":443}]',
              'alb.ingress.kubernetes.io/ssl-redirect': '443',
              'alb.ingress.kubernetes.io/certificate-arn': ACM_CERT_ARN,
              'alb.ingress.kubernetes.io/tags':          'Project=cbci-lab,ManagedBy=helm',
              'alb.ingress.kubernetes.io/group.name':    'cbci-oc',
              'alb.ingress.kubernetes.io/healthcheck-path': '/cjoc/login',
              'alb.ingress.kubernetes.io/success-codes': '200,302',
              'alb.ingress.kubernetes.io/target-group-attributes':
                'stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=86400,stickiness.type=lb_cookie',
            },
            tls: { Enable: false },
          },
        },

        // Controller ingress mirrors OC (same ALB group, same TLS)
        Master: {
          Ingress: {
            Class: 'alb',
            Annotations: {
              'alb.ingress.kubernetes.io/scheme':       'internet-facing',
              'alb.ingress.kubernetes.io/target-type':  'ip',
              'alb.ingress.kubernetes.io/listen-ports': '[{"HTTP":80},{"HTTPS":443}]',
              'alb.ingress.kubernetes.io/ssl-redirect': '443',
              'alb.ingress.kubernetes.io/certificate-arn': ACM_CERT_ARN,
              'alb.ingress.kubernetes.io/tags':          'Project=cbci-lab,ManagedBy=helm',
              'alb.ingress.kubernetes.io/group.name':    'cbci-oc',
              'alb.ingress.kubernetes.io/success-codes': '200,302',
              'alb.ingress.kubernetes.io/target-group-attributes':
                'stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=86400,stickiness.type=lb_cookie',
            },
            tls: { Enable: false },
          },
        },

        Agents: { SeparateNamespace: { Enabled: false } },

        Persistence: {
          StorageClass: 'efs-ap',
          AccessMode:   'ReadWriteOnce',
          Size:         '20Gi',
        },
      },
    });

    new cdk.CfnOutput(this, 'OcUrl', {
      value: `https://${OC_HOSTNAME}/cjoc/`,
    });
  }

  // ── Hazelcast RBAC manifests (Role + RoleBinding) ────────────────────────
  private hazelcastRbac(): object[] {
    return [
      {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind:       'Role',
        metadata:   { name: 'hazelcast-pod-reader', namespace: 'cloudbees' },
        rules: [{
          apiGroups: [''],
          resources: ['pods', 'endpoints', 'services'],
          verbs:     ['get', 'list', 'watch'],
        }],
      },
      {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind:       'RoleBinding',
        metadata:   { name: 'hazelcast-pod-reader', namespace: 'cloudbees' },
        roleRef: {
          apiGroup: 'rbac.authorization.k8s.io',
          kind:     'Role',
          name:     'hazelcast-pod-reader',
        },
        subjects: [{
          kind:      'ServiceAccount',
          name:      'jenkins',
          namespace: 'cloudbees',
        }],
      },
    ];
  }

  // ── HA gossip NetworkPolicies — one per controller ────────────────────────
  // Pods use label `tenant=<domain>` (CBCI's actual label, not com.cloudbees.master.app)
  private haGossipPolicies(): object[] {
    return ['devflow', 'test1'].map(name => ({
      apiVersion: 'networking.k8s.io/v1',
      kind:       'NetworkPolicy',
      metadata:   { name: `${name}-ha-gossip`, namespace: 'cloudbees' },
      spec: {
        podSelector:  { matchLabels: { tenant: name } },
        policyTypes:  ['Ingress', 'Egress'],
        ingress: [{
          from:  [{ podSelector: { matchLabels: { tenant: name } } }],
          ports: [{ port: 5701, protocol: 'TCP' }],
        }],
        egress: [
          {
            to:    [{ podSelector: { matchLabels: { tenant: name } } }],
            ports: [{ port: 5701, protocol: 'TCP' }],
          },
          {
            // K8s API for Hazelcast pod discovery
            ports: [{ port: 443, protocol: 'TCP' }, { port: 6443, protocol: 'TCP' }],
          },
        ],
      },
    }));
  }
}
