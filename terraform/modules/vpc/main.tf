# ─── Terraform VPC Module ─────────────────────────────────────────────────────
# This module creates ALL networking infrastructure:
# - VPC (your private network in AWS)
# - Public subnets (for ALB - faces the internet)
# - Private subnets (for EC2 - never directly internet-accessible)
# - Internet Gateway (allows VPC to reach internet)
# - NAT Gateway (allows private subnet to initiate outbound connections)
# - Route Tables (rules for where traffic goes)
#
# WHY THIS STRUCTURE:
# - ALB in public subnet = internet can send traffic TO your app
# - EC2 in private subnet = internet CANNOT directly connect to your servers
# - NAT Gateway = your servers CAN still download packages, pull images, etc.
# This is the standard AWS production network architecture.

# ─── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  # CIDR block: 10.0.0.0/16 gives us 65,536 IP addresses (10.0.0.0 - 10.0.255.255)
  # We'll carve this into smaller subnets
  cidr_block = var.vpc_cidr
  
  # enable_dns_hostnames: EC2 instances get DNS names like ec2-1-2-3-4.compute.amazonaws.com
  # Required for ECS, EKS, and many AWS services to work correctly
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

# ─── Internet Gateway ─────────────────────────────────────────────────────────
# IGW is what connects your VPC to the internet.
# Without it: nothing in your VPC can talk to the internet at all.
# With it: resources in PUBLIC subnets (with public IPs) can communicate with internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

# ─── Public Subnets ───────────────────────────────────────────────────────────
# Public subnets host resources that need to be internet-accessible:
# - Application Load Balancer (receives traffic from the internet)
# - NAT Gateway (needs internet access to route outbound traffic)
# - Bastion host if you need direct SSH access

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)
  
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  
  # Place subnets in different availability zones for redundancy
  # ap-south-1 has: ap-south-1a, ap-south-1b, ap-south-1c
  availability_zone = var.availability_zones[count.index]
  
  # Auto-assign public IP to any resource launched in this subnet
  # This is what makes it "public" - resources get internet-routable IPs
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
    Type = "public"
  })
}

# ─── Private Subnets ──────────────────────────────────────────────────────────
# Private subnets host resources that should NOT be directly internet-accessible:
# - EC2 application servers
# - Databases (RDS)
# - Cache servers (ElastiCache)
# Resources here have NO public IPs - they're invisible to the internet.

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)
  
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  
  # NO public IPs for private subnet resources
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
    Type = "private"
  })
}

# ─── NAT Gateway ─────────────────────────────────────────────────────────────
# NAT Gateway lets private subnet resources initiate OUTBOUND connections
# to the internet (e.g., downloading packages, pulling Docker images from ECR)
# WITHOUT allowing INBOUND connections from the internet.
#
# How it works:
# 1. EC2 in private subnet sends packet to 0.0.0.0/0 (internet)
# 2. Route table sends packet to NAT Gateway (in public subnet)
# 3. NAT Gateway replaces source IP with its own public IP
# 4. Response comes back to NAT Gateway's public IP
# 5. NAT Gateway forwards response back to the EC2 instance
#
# Cost note: NAT Gateway costs ~$0.045/hour + data processing fees
# This is often the most expensive part of a small AWS setup

# Elastic IP for the NAT Gateway (static public IP address)
resource "aws_eip" "nat" {
  domain = "vpc"
  
  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  # NAT Gateway must be in a PUBLIC subnet (it needs internet access)
  subnet_id     = aws_subnet.public[0].id
  allocation_id = aws_eip.nat.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-gateway"
  })

  # IGW must exist before we create NAT Gateway
  depends_on = [aws_internet_gateway.main]
}

# ─── Route Tables ─────────────────────────────────────────────────────────────
# Route tables are like the routing rules for your network.
# Each subnet is associated with exactly one route table.
# A route says: "traffic going to X should go through Y"

# Public Route Table: routes internet traffic through the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # This route says: traffic to anywhere on the internet (0.0.0.0/0)
  # should go through the Internet Gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

# Private Route Table: routes internet traffic through NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Traffic to internet goes through NAT Gateway (not directly)
  # This is what keeps private subnet resources invisible from internet
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-rt"
  })
}

# ─── Route Table Associations ─────────────────────────────────────────────────
# Associate each subnet with the correct route table

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
