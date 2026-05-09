# ── VPC ───────────────────────────────────────────────────────────────────

# The VPC is the private network boundary for all Garnersoft AWS resources.
# It isolates the infrastructure from other AWS accounts and gives full
# control over IP addressing, routing, and network access policies.
# DNS support and hostnames are enabled so EC2/EKS instances can resolve
# each other by hostname rather than IP address.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.domain_name}-vpc" })
}

# ── INTERNET GATEWAY ───────────────────────────────────────────────────────

# The Internet Gateway (IGW) is the VPC's connection to the public internet.
# Without it, resources in public subnets cannot send or receive internet
# traffic. It is also required for NAT Gateways to route outbound traffic
# from private subnets to the internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.domain_name}-igw" })
}

# ── PUBLIC SUBNETS ─────────────────────────────────────────────────────────

# Public subnets are created in each Availability Zone for high availability.
# Resources placed here (e.g. NAT Gateways, load balancers) receive a public
# IP and can communicate directly with the internet via the IGW.
# One subnet per AZ ensures the architecture survives an AZ failure.
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.domain_name}-public-${var.availability_zones[count.index]}"
    Tier = "Public"
  })
}

# ── PRIVATE SUBNETS ────────────────────────────────────────────────────────

# Private subnets host resources that should not be directly reachable from
# the internet (e.g. EKS worker nodes, application servers, databases).
# They have no public IPs and outbound internet access is routed through
# the NAT Gateway in the same AZ to avoid cross-AZ data transfer costs.
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.domain_name}-private-${var.availability_zones[count.index]}"
    Tier = "Private"
  })
}

# ── ELASTIC IPs FOR NAT GATEWAYS ───────────────────────────────────────────

# Each NAT Gateway requires a static Elastic IP address so that outbound
# traffic from private subnets always originates from a known, fixed IP.
# This is useful for whitelisting Garnersoft's IP with third-party APIs.
resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.domain_name}-nat-eip-${var.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ── NAT GATEWAYS (one per AZ for HA) ──────────────────────────────────────

# NAT Gateways allow resources in private subnets to initiate outbound
# internet connections (e.g. pulling container images, calling external APIs)
# without exposing them to inbound internet traffic.
# One NAT Gateway per AZ ensures private subnet traffic stays within the
# same AZ, avoiding cross-AZ data transfer charges and maintaining
# availability if one AZ goes down.
resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${var.domain_name}-nat-${var.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ── PUBLIC ROUTE TABLE ─────────────────────────────────────────────────────

# A single route table shared by all public subnets. The default route
# (0.0.0.0/0) points to the IGW so any resource in a public subnet can
# reach the internet and be reached from it.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "${var.domain_name}-public-rt" })
}

# Associates each public subnet with the public route table so the routing
# rules above apply to all resources launched in those subnets.
resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── PRIVATE ROUTE TABLES (one per AZ) ─────────────────────────────────────

# Each private subnet gets its own route table pointing to the NAT Gateway
# in the same AZ. Keeping route tables per-AZ means private subnet traffic
# never crosses AZ boundaries for outbound internet access, reducing latency
# and data transfer costs.
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.domain_name}-private-rt-${var.availability_zones[count.index]}"
  })
}

# Associates each private subnet with its corresponding per-AZ route table.
resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── SECURITY GROUPS ────────────────────────────────────────────────────────

# Public security group for internet-facing resources such as a load balancer
# or CloudFront origin. Allows inbound HTTP (80) and HTTPS (443) from anywhere
# and permits all outbound traffic so responses can be returned to clients.
resource "aws_security_group" "public" {
  name        = "${var.domain_name}-public-sg"
  description = "Allow inbound HTTPS and HTTP from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.domain_name}-public-sg" })
}

# Private security group for backend resources (EKS nodes, app servers).
# Only accepts traffic originating from the public security group, ensuring
# private resources are never directly reachable from the internet.
# All outbound traffic is allowed so instances can reach the internet via NAT.
resource "aws_security_group" "private" {
  name        = "${var.domain_name}-private-sg"
  description = "Allow inbound only from public security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From public tier only"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.public.id]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.domain_name}-private-sg" })
}
