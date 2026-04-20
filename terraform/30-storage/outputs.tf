output "efs_filesystem_id" {
  description = "EFS filesystem ID — used in StorageClass and PersistentVolumes"
  value       = aws_efs_file_system.cbci.id
}

output "efs_filesystem_arn" {
  description = "EFS filesystem ARN"
  value       = aws_efs_file_system.cbci.arn
}

output "efs_access_point_oc" {
  description = "Access point ID for the Operations Center (/oc)"
  value       = aws_efs_access_point.oc.id
}

output "efs_access_point_devflow" {
  description = "Access point ID for the devflow controller (/devflow)"
  value       = aws_efs_access_point.devflow.id
}

output "efs_security_group_id" {
  description = "Security group on EFS mount targets"
  value       = aws_security_group.efs.id
}
