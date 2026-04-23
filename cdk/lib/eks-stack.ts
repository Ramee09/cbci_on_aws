import * as cdk    from 'aws-cdk-lib';
import * as ec2    from 'aws-cdk-lib/aws-ec2';
import * as eks    from 'aws-cdk-lib/aws-eks';
import * as iam    from 'aws-cdk-lib/aws-iam';
import * as sqs    from 'aws-cdk-lib/aws-sqs';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import { KubectlV31Layer } from '@aws-cdk/lambda-layer-kubectl-v31';
import { Construct } from 'constructs';

const CLUSTER_NAME  = 'cbci-lab';
const KARPENTER_VER = '1.1.0';

export interface EksStackProps extends cdk.StackProps {
  vpc: ec2.Vpc;
}

export class EksStack extends cdk.Stack {
  public readonly cluster:           eks.Cluster;
  public readonly nodeSecurityGroup: ec2.ISecurityGroup;

  constructor(scope: Construct, id: string, props: EksStackProps) {
    super(scope, id, props);

    // ── EKS cluster ──────────────────────────────────────────────────────────
    this.cluster = new eks.Cluster(this, 'Cluster', {
      clusterName:    CLUSTER_NAME,
      version:        eks.KubernetesVersion.V1_31,
      kubectlLayer:   new KubectlV31Layer(this, 'KubectlLayer'),
      vpc:            props.vpc,
      vpcSubnets:     [{ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }],
      defaultCapacity: 0,
      endpointAccess:  eks.EndpointAccess.PUBLIC_AND_PRIVATE,
      // CDK manages ALB controller installation (IRSA role + Helm chart)
      albController:   { version: eks.AlbControllerVersion.V2_8_2 },
    });

    this.cluster.awsAuth.addUserMapping(
      iam.User.fromUserName(this, 'AdminUser', 'naga-admin'),
      { username: 'naga-admin', groups: ['system:masters'] },
    );

    // cluster.clusterSecurityGroup is an IMPORTED resource (fromSecurityGroupId).
    // Tags.of() is a no-op on imported resources — the tag never reaches EC2.
    // Use AwsCustomResource to call EC2:CreateTags so Karpenter can discover the SG.
    new cdk.custom_resources.AwsCustomResource(this, 'TagClusterSg', {
      onCreate: {
        service:  'EC2',
        action:   'createTags',
        parameters: {
          Resources: [this.cluster.clusterSecurityGroupId],
          Tags: [{ Key: 'karpenter.sh/discovery', Value: CLUSTER_NAME }],
        },
        physicalResourceId: cdk.custom_resources.PhysicalResourceId.of('TagClusterSg'),
      },
      policy: cdk.custom_resources.AwsCustomResourcePolicy.fromSdkCalls({
        resources: cdk.custom_resources.AwsCustomResourcePolicy.ANY_RESOURCE,
      }),
    });
    this.nodeSecurityGroup = this.cluster.clusterSecurityGroup;

    // ── System node group (platform pods: CoreDNS, kube-proxy, OC, LBC) ─────
    const systemNg = this.cluster.addNodegroupCapacity('SystemNodeGroup', {
      nodegroupName:  'system',
      instanceTypes:  [new ec2.InstanceType('t3.medium')],
      minSize:        2,
      maxSize:        4,
      desiredSize:    2,
      subnets:        { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      capacityType:   eks.CapacityType.ON_DEMAND,
      labels:         { role: 'system' },
      tags: {
        Name: `${CLUSTER_NAME}-system`,
        'karpenter.sh/discovery': CLUSTER_NAME,
      },
    });
    cdk.Tags.of(systemNg).add('karpenter.sh/nodepool', 'system');

    // ── Kubectl-backed resources — serialized to prevent Lambda rate limits ──
    //
    // All kubectl resources (addServiceAccount, addHelmChart, addManifest) share
    // a single kubectl Lambda function. CDK's albController prop installs the
    // ALB controller Helm chart concurrently with our resources. The ALB
    // controller registers a mutating webhook for ALL Services; ExternalDns
    // creates a Service during install and hits that webhook — but the ALB pods
    // aren't ready yet, so the webhook call fails with "no endpoints available".
    //
    // Fix: anchor ExternalDnsSa to the ALB controller Helm chart
    // (this.cluster.albController is public; 'Resource' is its HelmChart child).
    // ExternalDns only installs after ALB controller is fully deployed + webhook ready.
    //
    // Full chain: AlbChart → ExternalDnsSa → MetricsServer → ExternalDns →
    //   Karpenter → NodeClass → NodePools (last two wired inside addKarpenter)
    this.addEfsCsiAddon();
    const { sa: externalDnsSa, chart: externalDnsChart } = this.addExternalDns();
    const metricsChart                                   = this.addMetricsServer();
    const karpenterChart                                 = this.addKarpenter(props.vpc);

    // Anchor the chain to the ALB controller chart so ExternalDns never runs
    // before the ALB webhook is ready. albController is guaranteed non-null here
    // because we set albController: { version: ... } in the Cluster props above.
    const albChart = this.cluster.albController!.node.findChild('Resource');
    externalDnsSa.node.addDependency(albChart);
    metricsChart.node.addDependency(externalDnsSa);
    externalDnsChart.node.addDependency(metricsChart);
    karpenterChart.node.addDependency(externalDnsChart);
    // NodeClass and NodePools depend on karpenterChart inside addKarpenter()

    new cdk.CfnOutput(this, 'ClusterName',     { value: this.cluster.clusterName });
    new cdk.CfnOutput(this, 'ClusterEndpoint', { value: this.cluster.clusterEndpoint });
    new cdk.CfnOutput(this, 'KubeconfigCmd',   {
      value: `aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${this.region} --profile cbci-lab`,
    });
  }

  // ── EFS CSI add-on ─────────────────────────────────────────────────────────
  // The managed addon creates efs-csi-controller-sa internally. Using
  // cluster.addServiceAccount() for the same name fires a kubectl manifest
  // that conflicts → AlreadyExists. Instead, create the IRSA role directly
  // via CfnJson + WebIdentityPrincipal and let the addon own the SA.
  private addEfsCsiAddon(): void {
    const oidcConditions = new cdk.CfnJson(this, 'EfsCsiOidcConditions', {
      value: {
        [`${this.cluster.clusterOpenIdConnectIssuer}:sub`]:
          'system:serviceaccount:kube-system:efs-csi-controller-sa',
        [`${this.cluster.clusterOpenIdConnectIssuer}:aud`]: 'sts.amazonaws.com',
      },
    });

    const role = new iam.Role(this, 'EfsCsiSaRole', {
      assumedBy: new iam.WebIdentityPrincipal(
        this.cluster.openIdConnectProvider.openIdConnectProviderArn,
        { StringEquals: oidcConditions },
      ),
    });

    role.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: [
        'elasticfilesystem:DescribeAccessPoints',
        'elasticfilesystem:DescribeFileSystems',
        'elasticfilesystem:DescribeMountTargets',
        'elasticfilesystem:CreateAccessPoint',
        'elasticfilesystem:DeleteAccessPoint',
        'elasticfilesystem:TagResource',
        'ec2:DescribeAvailabilityZones',
      ],
      resources: ['*'],
    }));

    // CfnAddon uses the EKS API directly — not a kubectl Lambda call,
    // so it does not contribute to the concurrency problem.
    new eks.CfnAddon(this, 'EfsCsiAddon', {
      clusterName:           this.cluster.clusterName,
      addonName:             'aws-efs-csi-driver',
      addonVersion:          'v2.0.7-eksbuild.1',
      serviceAccountRoleArn: role.roleArn,
      resolveConflicts:      'OVERWRITE',
    });
  }

  // ── External DNS ────────────────────────────────────────────────────────────
  // Returns both the SA and HelmChart for dependency chaining.
  private addExternalDns(): { sa: eks.ServiceAccount; chart: eks.HelmChart } {
    const sa = this.cluster.addServiceAccount('ExternalDnsSa', {
      name:      'external-dns',
      namespace: 'kube-system',
    });

    sa.addToPrincipalPolicy(new iam.PolicyStatement({
      actions:   ['route53:ChangeResourceRecordSets'],
      resources: ['arn:aws:route53:::hostedzone/*'],
    }));
    sa.addToPrincipalPolicy(new iam.PolicyStatement({
      actions:   ['route53:ListHostedZones', 'route53:ListResourceRecordSets', 'route53:ListTagsForResource'],
      resources: ['*'],
    }));

    const chart = this.cluster.addHelmChart('ExternalDns', {
      chart:      'external-dns',
      repository: 'https://kubernetes-sigs.github.io/external-dns/',
      namespace:  'kube-system',
      release:    'external-dns',
      version:    '1.14.5',
      values: {
        provider:       'aws',
        aws:            { region: this.region },
        domainFilters:  ['myhomettbros.com'],
        txtOwnerId:     CLUSTER_NAME,
        policy:         'upsert-only',
        serviceAccount: {
          create:      false,
          name:        'external-dns',
          annotations: { 'eks.amazonaws.com/role-arn': sa.role.roleArn },
        },
      },
    });

    return { sa, chart };
  }

  // ── Metrics Server ───────────────────────────────────────────────────────────
  // Returns HelmChart for dependency chaining.
  private addMetricsServer(): eks.HelmChart {
    return this.cluster.addHelmChart('MetricsServer', {
      chart:      'metrics-server',
      repository: 'https://kubernetes-sigs.github.io/metrics-server/',
      namespace:  'kube-system',
      release:    'metrics-server',
      values:     { args: ['--kubelet-insecure-tls'] },
    });
  }

  // ── Karpenter ───────────────────────────────────────────────────────────────
  // Returns the Helm chart so the caller can place it in the dependency chain.
  private addKarpenter(vpc: ec2.Vpc): eks.HelmChart {
    const interruptionQueue = new sqs.Queue(this, 'KarpenterInterruptionQueue', {
      queueName:       CLUSTER_NAME,
      retentionPeriod: cdk.Duration.seconds(300),
      encryption:      sqs.QueueEncryption.SQS_MANAGED,
    });

    const eventSources: { id: string; source: string[]; detailType: string[] }[] = [
      { id: 'SpotInterruption',    source: ['aws.ec2'],    detailType: ['EC2 Spot Instance Interruption Warning'] },
      { id: 'ScheduledChange',     source: ['aws.health'], detailType: ['AWS Health Event'] },
      { id: 'InstanceStateChange', source: ['aws.ec2'],    detailType: ['EC2 Instance State-change Notification'] },
      { id: 'InstanceRebalance',   source: ['aws.ec2'],    detailType: ['EC2 Instance Rebalance Recommendation'] },
    ];
    eventSources.forEach(({ id, source, detailType }) =>
      new events.Rule(this, `Karpenter${id}Rule`, {
        eventPattern: { source, detailType },
        targets:      [new targets.SqsQueue(interruptionQueue)],
      }),
    );

    const nodeRole = new iam.Role(this, 'KarpenterNodeRole', {
      roleName:    `${CLUSTER_NAME}-karpenter-node`,
      assumedBy:   new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    this.cluster.awsAuth.addRoleMapping(nodeRole, {
      username: 'system:node:{{EC2PrivateDNSName}}',
      groups:   ['system:bootstrappers', 'system:nodes'],
    });

    const instanceProfile = new iam.CfnInstanceProfile(this, 'KarpenterInstanceProfile', {
      instanceProfileName: `${CLUSTER_NAME}-karpenter-node`,
      roles: [nodeRole.roleName],
    });

    // CfnJson defers OIDC issuer token (a CFN intrinsic) to deploy time so it
    // can be used as a map key in the IAM trust policy condition.
    const karpenterOidcConditions = new cdk.CfnJson(this, 'KarpenterOidcConditions', {
      value: {
        [`${this.cluster.clusterOpenIdConnectIssuer}:sub`]: 'system:serviceaccount:karpenter:karpenter',
        [`${this.cluster.clusterOpenIdConnectIssuer}:aud`]: 'sts.amazonaws.com',
      },
    });

    const controllerRole = new iam.Role(this, 'KarpenterControllerRole', {
      roleName:  `${CLUSTER_NAME}-karpenter-controller`,
      assumedBy: new iam.WebIdentityPrincipal(
        this.cluster.openIdConnectProvider.openIdConnectProviderArn,
        { StringEquals: karpenterOidcConditions },
      ),
    });

    controllerRole.addToPolicy(new iam.PolicyStatement({
      sid:     'AllowEC2AndPricing',
      actions: [
        'ec2:DescribeImages', 'ec2:RunInstances', 'ec2:DescribeLaunchTemplates',
        'ec2:DescribeInstances', 'ec2:DescribeSecurityGroups', 'ec2:DescribeSubnets',
        'ec2:DescribeInstanceTypes', 'ec2:DescribeInstanceTypeOfferings',
        'ec2:DescribeAvailabilityZones', 'ec2:CreateTags', 'ec2:CreateLaunchTemplate',
        'ec2:CreateFleet', 'ec2:DeleteLaunchTemplate', 'ec2:DescribeSpotPriceHistory',
        'pricing:GetProducts', 'eks:DescribeCluster', 'ssm:GetParameter',
      ],
      resources: ['*'],
    }));
    controllerRole.addToPolicy(new iam.PolicyStatement({
      sid:       'AllowTerminateKarpenterNodes',
      actions:   ['ec2:TerminateInstances'],
      resources: ['*'],
      conditions: { StringLike: { 'ec2:ResourceTag/karpenter.sh/nodepool': '*' } },
    }));
    controllerRole.addToPolicy(new iam.PolicyStatement({
      sid:       'AllowPassNodeRole',
      actions:   ['iam:PassRole'],
      resources: [nodeRole.roleArn],
      conditions: { StringEquals: { 'iam:PassedToService': 'ec2.amazonaws.com' } },
    }));
    controllerRole.addToPolicy(new iam.PolicyStatement({
      sid:       'AllowSqsInterruption',
      actions:   ['sqs:DeleteMessage', 'sqs:GetQueueAttributes', 'sqs:GetQueueUrl', 'sqs:ReceiveMessage'],
      resources: [interruptionQueue.queueArn],
    }));
    controllerRole.addToPolicy(new iam.PolicyStatement({
      sid:       'AllowInstanceProfileActions',
      actions:   ['iam:GetInstanceProfile'],
      resources: [`arn:aws:iam::${this.account}:instance-profile/${CLUSTER_NAME}-karpenter-node`],
    }));

    const karpenterChart = this.cluster.addHelmChart('Karpenter', {
      chart:           'karpenter',
      // CDK helm handler runs `helm pull <repository> --version <version>` for OCI.
      // The full chart path (including chart name) must be the repository value.
      repository:      'oci://public.ecr.aws/karpenter/karpenter',
      namespace:       'karpenter',
      release:         'karpenter',
      version:         KARPENTER_VER,
      createNamespace: true,
      values: {
        settings: { clusterName: CLUSTER_NAME, interruptionQueue: CLUSTER_NAME },
        serviceAccount: { annotations: { 'eks.amazonaws.com/role-arn': controllerRole.roleArn } },
        controller:  { resources: { requests: { cpu: '1', memory: '1Gi' }, limits: { cpu: '1', memory: '1Gi' } } },
        nodeSelector: { role: 'system' },
      },
    });
    karpenterChart.node.addDependency(instanceProfile);

    // ── EC2NodeClass + NodePools (serialized after Karpenter chart) ───────────
    const nodeClass = this.cluster.addManifest('KarpenterNodeClass', {
      apiVersion: 'karpenter.k8s.aws/v1',
      kind:       'EC2NodeClass',
      metadata:   { name: 'default' },
      spec: {
        amiFamily:         'AL2023',
        amiSelectorTerms:  [{ alias: 'al2023@latest' }],
        subnetSelectorTerms:        [{ tags: { 'karpenter.sh/discovery': CLUSTER_NAME } }],
        securityGroupSelectorTerms: [{ tags: { 'karpenter.sh/discovery': CLUSTER_NAME } }],
        instanceProfile: instanceProfile.instanceProfileName,
        blockDeviceMappings: [{
          deviceName: '/dev/xvda',
          ebs: { volumeSize: '50Gi', volumeType: 'gp3', encrypted: true },
        }],
      },
    });
    nodeClass.node.addDependency(karpenterChart);

    const controllersPool = this.cluster.addManifest('KarpenterControllersPool', {
      apiVersion: 'karpenter.sh/v1',
      kind:       'NodePool',
      metadata:   { name: 'controllers' },
      spec: {
        template: {
          metadata: { labels: { role: 'controller' } },
          spec: {
            nodeClassRef: { group: 'karpenter.k8s.aws', kind: 'EC2NodeClass', name: 'default' },
            requirements: [
              { key: 'karpenter.sh/capacity-type',       operator: 'In', values: ['on-demand'] },
              { key: 'node.kubernetes.io/instance-type',  operator: 'In', values: ['t3.large', 't3.xlarge'] },
              { key: 'topology.kubernetes.io/zone',       operator: 'In', values: ['us-east-1a', 'us-east-1b', 'us-east-1c'] },
            ],
          },
        },
        limits:     { cpu: '16' },
        disruption: { consolidationPolicy: 'WhenEmpty', consolidateAfter: '30s' },
      },
    });
    controllersPool.node.addDependency(nodeClass);

    const agentsPool = this.cluster.addManifest('KarpenterAgentsPool', {
      apiVersion: 'karpenter.sh/v1',
      kind:       'NodePool',
      metadata:   { name: 'agents' },
      spec: {
        template: {
          metadata: { labels: { role: 'agent' } },
          spec: {
            nodeClassRef: { group: 'karpenter.k8s.aws', kind: 'EC2NodeClass', name: 'default' },
            taints:       [{ key: 'workload', value: 'agents', effect: 'NoSchedule' }],
            requirements: [
              { key: 'karpenter.sh/capacity-type',       operator: 'In', values: ['spot', 'on-demand'] },
              { key: 'node.kubernetes.io/instance-type',  operator: 'In', values: ['t3.medium', 't3.large', 'm5.large', 'm5.xlarge'] },
              { key: 'topology.kubernetes.io/zone',       operator: 'In', values: ['us-east-1a', 'us-east-1b', 'us-east-1c'] },
            ],
          },
        },
        limits:     { cpu: '32' },
        disruption: { consolidationPolicy: 'WhenEmptyOrUnderutilized', consolidateAfter: '30s' },
      },
    });
    agentsPool.node.addDependency(nodeClass);

    return karpenterChart;
  }
}
