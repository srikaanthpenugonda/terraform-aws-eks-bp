locals {
  account_id = data.aws_caller_identity.current.account_id
  dns_suffix = data.aws_partition.current.dns_suffix
  partition  = data.aws_partition.current.id
  region     = data.aws_region.current.name

  # Managed node IAM Roles for aws-auth
  managed_node_group_aws_auth_config_map = length(var.managed_node_groups) > 0 == true ? [
    for key, node in var.managed_node_groups : {
      rolearn : try(node.iam_role_arn, "arn:${local.partition}:iam::${local.account_id}:role/${module.eks.cluster_id}-${node.node_group_name}")
      username : "system:node:{{EC2PrivateDNSName}}"
      groups : [
        "system:bootstrappers",
        "system:nodes"
      ]
    }
  ] : []

  # Self Managed node IAM Roles for aws-auth
  self_managed_node_group_aws_auth_config_map = [
    for role_arn in distinct(compact([for group in module.eks.self_managed_node_groups : group.iam_role_arn if group.platform != "windows"])) : {
      rolearn : role_arn
      username : "system:node:{{EC2PrivateDNSName}}"
      groups : [
        "system:bootstrappers",
        "system:nodes"
      ]
    }
  ]

  # Self Managed Windows node IAM Roles for aws-auth
  windows_node_group_aws_auth_config_map = [
    for role_arn in distinct(compact([for group in module.eks.self_managed_node_groups : group.iam_role_arn if group.platform == "windows"])) : {
      rolearn : role_arn
      username : "system:node:{{EC2PrivateDNSName}}"
      groups : [
        "system:bootstrappers",
        "system:nodes",
        "eks:kube-proxy-windows"
      ]
    }
  ]

  # Fargate node IAM Roles for aws-auth
  fargate_profiles_aws_auth_config_map = [
    for role in distinct(compact([for profile in module.eks.fargate_profiles : profile.fargate_profile_pod_execution_role_arn])) : {
      rolearn : role
      username : "system:node:{{SessionName}}"
      groups : [
        "system:bootstrappers",
        "system:nodes",
        "system:node-proxier"
      ]
    }
  ]

  # EMR on EKS IAM Roles for aws-auth
  emr_on_eks_config_map = var.enable_emr_on_eks == true ? [
    {
      rolearn : "arn:${local.partition}:iam::${local.account_id}:role/AWSServiceRoleForAmazonEMRContainers"
      username : "emr-containers"
      groups : []
    }
  ] : []

  # TODO - move this into `aws-eks-teams` to avoid getting out of sync
  platform_teams_config_map = length(var.platform_teams) > 0 ? [
    for platform_team_name, platform_team_data in var.platform_teams : {
      rolearn : "arn:${local.partition}:iam::${local.account_id}:role/${module.eks.cluster_id}-${platform_team_name}-access"
      username : "${platform_team_name}"
      groups : [
        "system:masters"
      ]
    }
  ] : []

  # TODO - move this into `aws-eks-teams` to avoid getting out of sync
  application_teams_config_map = length(var.application_teams) > 0 ? [
    for team_name, team_data in var.application_teams : {
      rolearn : "arn:${local.partition}:iam::${local.account_id}:role/${module.eks.cluster_id}-${team_name}-access"
      username : "${team_name}"
      groups : [
        "${team_name}-group"
      ]
    }
  ] : []
}

resource "kubernetes_config_map" "aws_auth" {
  count = var.create_eks ? 1 : 0

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform-aws-eks-blueprints"
        "app.kubernetes.io/created-by" = "terraform-aws-eks-blueprints"
      },
      var.aws_auth_additional_labels
    )
  }

  data = {
    mapRoles = yamlencode(
      distinct(concat(
        local.managed_node_group_aws_auth_config_map,
        local.self_managed_node_group_aws_auth_config_map,
        local.windows_node_group_aws_auth_config_map,
        local.fargate_profiles_aws_auth_config_map,
        local.emr_on_eks_config_map,
        local.application_teams_config_map,
        local.platform_teams_config_map,
        var.map_roles,
      ))
    )
    mapUsers    = yamlencode(var.map_users)
    mapAccounts = yamlencode(var.map_accounts)
  }

  depends_on = [
    module.eks.cluster_id,
    data.http.eks_cluster_readiness[0],
  ]
}
