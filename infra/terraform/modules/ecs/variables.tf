variable "name"                 { type = string }
variable "vpc_id"               { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "security_group_ids"   { type = list(string) }
variable "data_bucket_name"     { type = string }
variable "region"               { type = string }