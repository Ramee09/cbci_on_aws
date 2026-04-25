import * as cdk from 'aws-cdk-lib';
import * as ec2  from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

const CLUSTER_NAME = 'cbci-lab';

export class NetworkStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    this.vpc = new ec2.Vpc(this, 'Vpc', {
      vpcName: CLUSTER_NAME,
      ipAddresses: ec2.IpAddresses.cidr('10.0.0.0/16'),
      maxAzs: 3,
      natGateways: 1,   // single NAT — lab cost ~$32/mo
      subnetConfiguration: [
        {
          name:       'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask:   20,
        },
        {
          name:       'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask:   20,
        },
      ],
    });

    // Tags required by EKS (ALB ingress controller reads these)
    this.vpc.publicSubnets.forEach(subnet => {
      cdk.Tags.of(subnet).add('kubernetes.io/role/elb', '1');
      cdk.Tags.of(subnet).add(`kubernetes.io/cluster/${CLUSTER_NAME}`, 'shared');
    });

    // Tags required by EKS + Karpenter subnet/SG discovery
    this.vpc.privateSubnets.forEach(subnet => {
      cdk.Tags.of(subnet).add('kubernetes.io/role/internal-elb', '1');
      cdk.Tags.of(subnet).add(`kubernetes.io/cluster/${CLUSTER_NAME}`, 'shared');
      cdk.Tags.of(subnet).add('karpenter.sh/discovery', CLUSTER_NAME);
    });

    new cdk.CfnOutput(this, 'VpcId', { value: this.vpc.vpcId });
  }
}
