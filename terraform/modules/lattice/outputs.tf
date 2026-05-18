output "service_network_arn" {
  description = "ARN of the VPC Lattice service network"
  value       = aws_vpclattice_service_network.main.arn
}

output "service_network_id" {
  description = "ID of the VPC Lattice service network"
  value       = aws_vpclattice_service_network.main.id
}

output "market_data_service_arn" {
  description = "ARN of the market data VPC Lattice service"
  value       = aws_vpclattice_service.market_data.arn
}

output "market_data_service_dns" {
  description = "DNS name of the market data VPC Lattice service"
  value       = aws_vpclattice_service.market_data.dns_entry[0].domain_name
}

output "order_execution_api_service_arn" {
  description = "ARN of the order execution VPC Lattice service"
  value       = aws_vpclattice_service.order_execution_api.arn
}

output "order_execution_api_service_dns" {
  description = "DNS name of the order execution VPC Lattice service"
  value       = aws_vpclattice_service.order_execution_api.dns_entry[0].domain_name
}
