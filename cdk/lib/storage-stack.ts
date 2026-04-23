import * as cdk from 'aws-cdk-lib';
import * as ec2  from 'aws-cdk-lib/aws-ec2';
import * as efs  from 'aws-cdk-lib/aws-efs';
import * as kms  from 'aws-cdk-lib/aws-kms';
import { Construct } from 'constructs';

export interface StorageStackProps extends cdk.StackProps {
  vpc:                 ec2.Vpc;
  nodeSecurityGroupId: string;   // ID string avoids cross-stack SG object reference cycle
}

export class StorageStack extends cdk.Stack {
  public readonly fileSystemId: string;

  constructor(scope: Construct, id: string, props: StorageStackProps) {
    super(scope, id, props);

    // ── KMS key for EFS encryption ───────────────────────────────────────────
    const key = new kms.Key(this, 'EfsKey', {
      alias:          'alias/cbci-lab-efs',
      description:    'KMS key for CBCI EFS filesystem',
      enableKeyRotation: true,
      removalPolicy:  cdk.RemovalPolicy.RETAIN,
    });

    // ── Security group: allow NFS from EKS nodes ─────────────────────────────
    const efsSg = new ec2.SecurityGroup(this, 'EfsSg', {
      vpc:         props.vpc,
      description: 'Allow NFS from EKS nodes to CBCI EFS',
    });
    efsSg.addIngressRule(
      ec2.Peer.securityGroupId(props.nodeSecurityGroupId),
      ec2.Port.tcp(2049),
      'NFS from EKS cluster SG',
    );

    // ── EFS filesystem ────────────────────────────────────────────────────────
    // Elastic throughput: best for Jenkins spiky I/O (no provisioned throughput cost)
    const fileSystem = new efs.FileSystem(this, 'EfsFileSystem', {
      fileSystemName:  'cbci-lab',
      vpc:             props.vpc,
      performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode:  efs.ThroughputMode.ELASTIC,
      encrypted:       true,
      kmsKey:          key,
      securityGroup:   efsSg,
      vpcSubnets:      { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      removalPolicy:   cdk.RemovalPolicy.RETAIN,   // never accidentally delete Jenkins data
    });

    this.fileSystemId = fileSystem.fileSystemId;

    new cdk.CfnOutput(this, 'EfsFileSystemId', { value: fileSystem.fileSystemId });
  }
}
