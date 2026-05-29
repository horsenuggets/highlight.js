terraform {
  required_version = ">= 1.5"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "github" {
  owner = "horsenuggets"
  # Authenticates via GITHUB_TOKEN environment variable
}

locals {
  repo_name = "highlight.js"

  # CI runs on every PR via the existing GitHub Actions workflows. We gate
  # main on the lint job since it is the project's authoritative style and
  # correctness check; the markup test suite runs inside lint via
  # `npm run lint` so it is covered transitively.
  required_checks = [
    "lint",
  ]
}

# Import the existing repository into state on first apply. The repo was
# forked via the GitHub UI before this Terraform was introduced, so without
# an import block `terraform apply` would attempt to create it and fail with
# "name already exists on this account".
import {
  to = github_repository.highlight_js
  # Terraform 1.5 requires the import block id to be a literal string known
  # at plan time (expression-valued ids were added in 1.6). Keep this in
  # sync with local.repo_name above.
  id = "highlight.js"
}

resource "github_repository" "highlight_js" {
  name = local.repo_name

  has_issues   = true
  has_projects = false
  has_wiki     = false

  allow_squash_merge = true
  allow_merge_commit = false
  allow_rebase_merge = false

  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "PR_BODY"

  delete_branch_on_merge = true

  # description, visibility, and topics are managed via the GitHub UI (or by
  # the user) and ignored here so applies don't clobber out-of-band edits.
  # has_downloads is deprecated by the provider.
  lifecycle {
    ignore_changes = [
      description,
      visibility,
      topics,
      has_downloads,
    ]
  }
}

# Branch protection for main: require all merges to go through a PR. We
# don't require human approving reviews (`required_approving_review_count =
# 0`) because Copilot review is the gate (`copilot_code_review.review_on_push`),
# matching the established horsenuggets convention.
resource "github_repository_ruleset" "main" {
  name        = "main"
  repository  = github_repository.highlight_js.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    pull_request {
      required_approving_review_count = 0
      dismiss_stale_reviews_on_push   = true
    }

    # Automatically request Copilot code review on every non-draft PR.
    copilot_code_review {
      review_on_push             = true
      review_draft_pull_requests = false
    }

    dynamic "required_status_checks" {
      for_each = length(local.required_checks) > 0 ? [1] : []
      content {
        dynamic "required_check" {
          for_each = local.required_checks
          content {
            context        = required_check.value
            integration_id = 0
          }
        }
      }
    }
  }
}
