# VPC Lattice Service Network
resource "aws_vpclattice_service_network" "main" {
  name      = "nasdaq-service-network"
  auth_type = "NONE"

  tags = merge(var.tags, {
    Name = "nasdaq-service-network"
  })
}

# Market Data Service
resource "aws_vpclattice_service" "market_data" {
  name      = "market-data-service"
  auth_type = "NONE"

  tags = merge(var.tags, {
    Name = "market-data-service"
  })
}

# Order Execution API Service
resource "aws_vpclattice_service" "order_execution_api" {
  name      = "order-execution-api"
  auth_type = "NONE"

  tags = merge(var.tags, {
    Name = "order-execution-api"
  })
}

# Service Network VPC Associations
resource "aws_vpclattice_service_network_vpc_association" "dev" {
  vpc_identifier             = var.dev_vpc_id
  service_network_identifier = aws_vpclattice_service_network.main.id

  tags = merge(var.tags, {
    Name        = "nasdaq-service-network-dev-association"
    Environment = "dev"
  })
}

resource "aws_vpclattice_service_network_vpc_association" "prod" {
  vpc_identifier             = var.prod_vpc_id
  service_network_identifier = aws_vpclattice_service_network.main.id

  tags = merge(var.tags, {
    Name        = "nasdaq-service-network-prod-association"
    Environment = "prod"
  })
}

# Service Network Service Associations
resource "aws_vpclattice_service_network_service_association" "market_data" {
  service_identifier         = aws_vpclattice_service.market_data.id
  service_network_identifier = aws_vpclattice_service_network.main.id

  tags = var.tags
}

resource "aws_vpclattice_service_network_service_association" "order_execution_api" {
  service_identifier         = aws_vpclattice_service.order_execution_api.id
  service_network_identifier = aws_vpclattice_service_network.main.id

  tags = var.tags
}

# Target Group: Market Data (Dev)
resource "aws_vpclattice_target_group" "market_data_dev" {
  name = "market-data-dev"
  type = "IP"

  config {
    vpc_identifier   = var.dev_vpc_id
    port             = 8080
    protocol         = "HTTP"
    ip_address_type  = "IPV4"

    health_check {
      enabled                 = true
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      path                          = "/health"
      protocol                      = "HTTP"
      protocol_version              = "HTTP1"
      matcher {
        value = "200"
      }
    }
  }

  tags = merge(var.tags, {
    Name        = "market-data-dev"
    Environment = "dev"
  })
}

# Target Group: Market Data (Prod)
resource "aws_vpclattice_target_group" "market_data_prod" {
  name = "market-data-prod"
  type = "IP"

  config {
    vpc_identifier  = var.prod_vpc_id
    port            = 8080
    protocol        = "HTTP"
    ip_address_type = "IPV4"

    health_check {
      enabled                       = true
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      path                          = "/health"
      protocol                      = "HTTP"
      protocol_version              = "HTTP1"
      matcher {
        value = "200"
      }
    }
  }

  tags = merge(var.tags, {
    Name        = "market-data-prod"
    Environment = "prod"
  })
}

# Target Group: Order Execution (Dev)
resource "aws_vpclattice_target_group" "order_execution_dev" {
  name = "order-execution-dev"
  type = "IP"

  config {
    vpc_identifier  = var.dev_vpc_id
    port            = 8080
    protocol        = "HTTP"
    ip_address_type = "IPV4"

    health_check {
      enabled                       = true
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      path                          = "/health"
      protocol                      = "HTTP"
      protocol_version              = "HTTP1"
      matcher {
        value = "200"
      }
    }
  }

  tags = merge(var.tags, {
    Name        = "order-execution-dev"
    Environment = "dev"
  })
}

# Target Group: Order Execution (Prod)
resource "aws_vpclattice_target_group" "order_execution_prod" {
  name = "order-execution-prod"
  type = "IP"

  config {
    vpc_identifier  = var.prod_vpc_id
    port            = 8080
    protocol        = "HTTP"
    ip_address_type = "IPV4"

    health_check {
      enabled                       = true
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      path                          = "/health"
      protocol                      = "HTTP"
      protocol_version              = "HTTP1"
      matcher {
        value = "200"
      }
    }
  }

  tags = merge(var.tags, {
    Name        = "order-execution-prod"
    Environment = "prod"
  })
}

# Listener: Market Data Service (HTTP:80)
resource "aws_vpclattice_listener" "market_data" {
  name               = "market-data-http"
  protocol           = "HTTP"
  port               = 80
  service_identifier = aws_vpclattice_service.market_data.id

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.market_data_prod.id
        weight                  = 100
      }
    }
  }

  tags = var.tags
}

# Listener: Order Execution API (HTTP:80)
resource "aws_vpclattice_listener" "order_execution_api" {
  name               = "order-execution-http"
  protocol           = "HTTP"
  port               = 80
  service_identifier = aws_vpclattice_service.order_execution_api.id

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.order_execution_prod.id
        weight                  = 100
      }
    }
  }

  tags = var.tags
}

# Routing Rule: Path-based routing for market data API
resource "aws_vpclattice_listener_rule" "market_data_api_v1" {
  name                = "market-data-api-v1"
  listener_identifier = aws_vpclattice_listener.market_data.id
  service_identifier  = aws_vpclattice_service.market_data.id
  priority            = 10

  match {
    http_match {
      path_match {
        match {
          prefix = "/api/v1/market-data/"
        }
        case_sensitive = false
      }
    }
  }

  action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.market_data_prod.id
        weight                  = 100
      }
    }
  }

  tags = var.tags
}
