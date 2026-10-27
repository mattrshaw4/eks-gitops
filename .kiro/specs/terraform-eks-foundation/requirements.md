# Requirements Document

## Introduction

This feature delivers the Terraform foundation for an EKS-based GitOps platform. The infrastructure lives in the `infra/` directory at the workspace root and provisions a lab-grade AWS environment: a VPC spanning two availability zones, an EKS cluster with Auto Mode enabled, API-mode cluster authentication backed by IAM Identity Center, and an AWS Budget alarm. All region-specific and account-specific values are injected through Terraform variables so the configuration remains portable. Argo CD provisioning is explicitly out of scope and handled in a separate spec.

## Glossary

- **Terraform_Module**: The collection of `.tf` files under `infra/` that constitute the root Terraform configuration.
- **VPC**: The AWS Virtual Private Cloud created by the Terraform_Module.
- **EKS_Cluster**: The Amazon Elastic Kubernetes Service cluster created by the Terraform_Module.
- **Auto_Mode**: The EKS cluster compute management mode where AWS fully manages node provisioning and lifecycle.
- **NAT_Gateway**: The single AWS NAT Gateway that provides outbound internet access for private subnets.
- **Access_Entry**: An EKS API-mode access entry that maps an IAM principal to a Kubernetes RBAC permission set.
- **Identity_Center_Role**: The IAM role for the AWS IAM Identity Center AdministratorAccess permission set, discovered at plan time via a `data.aws_iam_roles` lookup rather than supplied as a variable.
- **Budget_Alarm**: The AWS Budgets resource that sends a notification when forecasted or actual spend crosses a configured threshold.
- **Variable**: A Terraform input variable declared in `variables.tf`.
- **Default_Tags**: Provider-level tags applied to every AWS resource created by the Terraform_Module.

---

## Requirements

### Requirement 1: VPC Network Foundation

**User Story:** As a platform engineer, I want a VPC with public and private subnets spread across two availability zones, so that the EKS cluster has isolated, highly-available networking.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create a VPC with a configurable CIDR block supplied through a Variable.
2. THE Terraform_Module SHALL create one public subnet and one private subnet in each of exactly two availability zones (four subnets total).
3. THE Terraform_Module SHALL create a single NAT_Gateway in one of the public subnets to provide outbound internet access for all private subnets.
4. THE Terraform_Module SHALL create an Internet Gateway and attach it to the VPC.
5. THE Terraform_Module SHALL configure route tables so that private subnets route all traffic destined for 0.0.0.0/0 through the NAT_Gateway and public subnets route all traffic destined for 0.0.0.0/0 through the Internet Gateway.
6. THE Terraform_Module SHALL tag all VPC resources with the Kubernetes cluster discovery tag `kubernetes.io/cluster/<cluster_name>` set to the value `shared`, and shall tag each public subnet with `kubernetes.io/role/elb = 1` and each private subnet with `kubernetes.io/role/internal-elb = 1`.
7. IF the Variable for availability zones is not provided, THEN THE Terraform_Module SHALL default to the first two availability zones in lexicographic ascending order as returned by the AWS provider for the configured region.

---

### Requirement 2: EKS Cluster with Auto Mode

**User Story:** As a platform engineer, I want an EKS cluster with Auto Mode enabled on the latest supported Kubernetes version, so that node lifecycle is fully managed by AWS without manual node group configuration.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create an EKS_Cluster using the Kubernetes version supplied through a Variable whose default value is set to the latest Kubernetes version supported by EKS Auto Mode at the time of authoring and documented in the Variable description.
2. THE Terraform_Module SHALL enable Auto_Mode on the EKS_Cluster by configuring all of the following together: `compute_config` enabled with `node_pools = ["general-purpose", "system"]`; `kubernetes_network_config` with `elastic_load_balancing` enabled; `storage_config` with `block_storage` enabled; and `bootstrap_self_managed_addons = false`.
3. THE Terraform_Module SHALL place the EKS_Cluster control plane endpoint in the private subnets created by Requirement 1, with public endpoint access enabled by default and restricted to the CIDR ranges supplied through the required `api_allowed_cidrs` Variable.
4. THE Terraform_Module SHALL create the EKS cluster IAM role whose trust policy allows both `sts:AssumeRole` and `sts:TagSession` for the `eks.amazonaws.com` service principal, with the AWS-managed policies `AmazonEKSClusterPolicy`, `AmazonEKSComputePolicy`, `AmazonEKSBlockStoragePolicy`, `AmazonEKSLoadBalancingPolicy`, and `AmazonEKSNetworkingPolicy` attached, and associate that role with the EKS_Cluster.
5. THE Terraform_Module SHALL create the EKS node IAM role with the AWS-managed policies `AmazonEKSWorkerNodeMinimalPolicy` and `AmazonEC2ContainerRegistryPullOnly` attached, and configure the EKS_Cluster Auto Mode node role ARN to reference it.
6. THE Terraform_Module SHALL output the EKS_Cluster name, API server endpoint, cluster certificate authority data, and OIDC issuer URL as Terraform outputs.

---

### Requirement 3: API Authentication Mode and Identity Center Admin Access

**User Story:** As a platform engineer, I want the EKS cluster to use API authentication mode with an access entry for my Identity Center AdministratorAccess role, so that I can authenticate to the cluster using my SSO identity without managing a separate aws-auth ConfigMap.

#### Acceptance Criteria

1. THE Terraform_Module SHALL configure the EKS_Cluster authentication mode to `API` (not `CONFIG_MAP` or `API_AND_CONFIG_MAP`).
2. THE Terraform_Module SHALL discover the Identity_Center_Role at plan time using a `data.aws_iam_roles` data source that filters by name pattern `AWSReservedSSO_AdministratorAccess_*` under path `/aws-reserved/sso.amazonaws.com/`, and SHALL use the resulting role ARN as the principal for the Access_Entry.
3. THE Terraform_Module SHALL associate the `AmazonEKSClusterAdminPolicy` access policy with the Access_Entry using a policy scope type of `Cluster`.
4. IF the `data.aws_iam_roles` lookup returns zero matching roles or more than one matching role, THEN THE Terraform_Module SHALL fail at plan time with a `precondition` or `validation` error whose message states how many roles were found and instructs the operator to verify the Identity Center AdministratorAccess permission set assignment in the account.
5. THE Terraform_Module SHALL use `data.aws_caller_identity.current.account_id` wherever an account-scoped value is needed, eliminating the need for a separate `account_id` Variable.

---

### Requirement 4: AWS Budget Alarm

**User Story:** As a platform engineer, I want an AWS Budget alarm on the account, so that I receive a notification before spend exceeds a configured monthly limit.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create a Budget_Alarm of type `COST` with a monthly time period.
2. THE Terraform_Module SHALL accept the budget limit amount through a Variable with a default value of `30` and the currency unit through a Variable with a default value of `USD`.
3. THE Terraform_Module SHALL accept between 1 and 10 notification email addresses through a Variable and configure the Budget_Alarm to send email notifications to each address.
4. WHEN forecasted monthly spend is projected to exceed 100% of the budget limit, THE Budget_Alarm SHALL send a notification to all configured email addresses.
5. WHEN actual monthly spend exceeds 80% of the budget limit, THE Budget_Alarm SHALL send a notification to all configured email addresses.

---

### Requirement 5: Terraform Variable Interface

**User Story:** As a platform engineer, I want all environment-specific values supplied through Terraform variables, so that the same configuration can be applied to different accounts and regions without modifying source files.

#### Acceptance Criteria

1. THE Terraform_Module SHALL declare all region-specific, account-specific, and environment-specific values as Variables with non-empty description strings and explicit type constraints.
2. THE Terraform_Module SHALL include a `region` Variable that controls the AWS provider region.
3. THE Terraform_Module SHALL include an `api_allowed_cidrs` Variable of type `list(string)` with no default value (required), and SHALL include a validation rule that rejects any list containing `"0.0.0.0/0"`, producing an error message that instructs the operator to supply one or more specific CIDR ranges.
4. THE Terraform_Module SHALL provide a `terraform.tfvars.example` file listing every declared Variable with a non-empty placeholder value and an inline comment of at least one word explaining its purpose.

---

### Requirement 6: Resource Tagging

**User Story:** As a platform engineer, I want every AWS resource created by the Terraform module tagged with project and owner labels, so that cost allocation and resource ownership are immediately visible in the AWS console.

#### Acceptance Criteria

1. THE Terraform_Module SHALL configure the AWS provider with `default_tags` that apply `project = "eks-gitops"` and `owner = "matt-shaw"` to every resource created by the provider.
2. THE Terraform_Module SHALL NOT declare individual resource-level tags that duplicate the `project` or `owner` keys already applied by Default_Tags.

---

### Requirement 7: Clean Destroy

**User Story:** As a platform engineer, I want `terraform destroy` to remove every resource the module created, so that I can tear down the lab environment completely without manual cleanup.

#### Acceptance Criteria

1. WHEN `terraform destroy` is executed, THE Terraform_Module SHALL remove all AWS resources it created, including the VPC, subnets, Internet Gateway, NAT_Gateway, route tables, EKS_Cluster, IAM roles, access entries, and Budget_Alarm, leaving no orphaned resources in the account.
2. THE Terraform_Module SHALL NOT create resources outside of Terraform state management (e.g., no local-exec provisioners that create AWS resources) that would survive a `terraform destroy`.

---

### Requirement 8: Verification Checks

**User Story:** As a platform engineer, I want a set of testable verification steps I can run after `terraform apply`, so that I can confirm the cluster is healthy and access controls are working before proceeding with further configuration.

#### Acceptance Criteria

1. WHEN `terraform apply` completes successfully, running `aws eks describe-cluster --name <cluster_name> --region <region>` SHALL return a JSON response where `cluster.status` equals `ACTIVE`.
2. WHEN `terraform apply` completes successfully, running `kubectl get nodepools` against the cluster SHALL list entries named `general-purpose` and `system`.
3. WHEN `terraform apply` completes successfully, running `kubectl auth can-i '*' '*'` using the `eks-lab` AWS CLI profile SHALL return `yes`, confirming that the Identity_Center_Role has cluster-admin permissions.
