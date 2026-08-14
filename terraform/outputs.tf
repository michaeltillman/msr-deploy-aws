output "public_ip" {
  description = "Elastic IP of the MSR node"
  value       = aws_eip.msr.public_ip
}

output "msr_url" {
  description = "MSR UI / registry URL"
  value       = "https://${aws_eip.msr.public_ip}:${var.msr_https_nodeport}"
}

output "ssh_command" {
  description = "SSH into the MSR node"
  value       = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${aws_eip.msr.public_ip}"
}

output "allowed_cidr" {
  description = "CIDR granted access to SSH and the MSR UI"
  value       = local.allowed_cidr
}
