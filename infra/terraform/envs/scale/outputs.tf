output "cluster_name" {
  value = module.stack.cluster_name
}

output "cluster_endpoint" {
  value = module.stack.cluster_endpoint
}

output "region" {
  value = var.region
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.stack.cluster_name} --region ${var.region} --profile ${var.aws_profile}"
}

output "model_bucket" {
  value = module.stack.model_bucket
}

output "vpc_id" {
  value = module.stack.vpc_id
}

output "karpenter_queue_name" {
  value = module.stack.karpenter_queue_name
}

output "karpenter_node_role_name" {
  value = module.stack.karpenter_node_role_name
}
