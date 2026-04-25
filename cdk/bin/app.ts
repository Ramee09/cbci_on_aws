#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NetworkStack } from '../lib/network-stack';
import { EksStack } from '../lib/eks-stack';
import { StorageStack } from '../lib/storage-stack';
import { CbciStack } from '../lib/cbci-stack';

const app = new cdk.App();

const env = {
  account: '835090871306',
  region:  'us-east-1',
};

// Stack 1 — VPC + networking
const networkStack = new NetworkStack(app, 'CbciNetworkStack', { env });

// Stack 2 — EKS cluster + addons + Karpenter
const eksStack = new EksStack(app, 'CbciEksStack', {
  env,
  vpc: networkStack.vpc,
});
eksStack.addDependency(networkStack);

// Stack 3 — EFS filesystem + StorageClass
const storageStack = new StorageStack(app, 'CbciStorageStack', {
  env,
  vpc:                 networkStack.vpc,
  nodeSecurityGroupId: eksStack.nodeSecurityGroup.securityGroupId,
});
storageStack.addDependency(eksStack);

// Stack 4 — CBCI Helm + k8s resources
const cbciStack = new CbciStack(app, 'CbciStack', {
  env,
  cluster:      eksStack.cluster,
  fileSystemId: storageStack.fileSystemId,
});
cbciStack.addDependency(storageStack);
