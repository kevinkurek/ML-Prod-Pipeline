variable "repositories" { type = list(string) }
resource "aws_ecr_repository" "repos" {
  for_each             = toset(var.repositories)
  name                 = each.key
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}
output "repo_urls" { value = { for k, v in aws_ecr_repository.repos : k => v.repository_url } }
