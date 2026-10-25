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
  # main on the lint check (ESLint, from .github/workflows/lint.yml) plus a
  # representative slice of the Node.js CI matrix (from tests.js.yml). The
  # markup test suite runs inside `npm test` during the `node` build leg,
  # and `test-browser` runs inside the `browser*` / `cdn` legs, so listing
  # the latest LTS node version's matrix entries covers both. Older Node
  # versions in the matrix are not gated so the protection survives when
  # they EOL out of the workflow.
  required_checks = [
    "lint",
    "build (22.x, node)",
    "build (22.x, browser)",
    "build (22.x, browser -n)",
    "build (22.x, cdn :common)",
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

# Branch protection for main: require all merges to go through a PR with one
# approving review. Copilot reviews every push (`copilot_code_review.review_on_push`)
# and its approval is the gate, which needs "Allow Copilot to approve pull
# requests" turned on in the repo's Copilot code review settings.
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
      required_approving_review_count = 1
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

# The GitHub provider can't manage Copilot code review settings yet, so this calls the
# REST endpoint directly to run automatic reviews at the Lite effort level. It re-runs
# whenever the repo or the effort level changes. Lite reviews cost several times fewer AI
# credits than the Balanced default.
resource "terraform_data" "copilot_review_effort" {
  triggers_replace = [github_repository.highlight_js.full_name, "lite"]

  provisioner "local-exec" {
    command = <<-EOT
      : "$${GITHUB_TOKEN:?GITHUB_TOKEN must be set to update Copilot code review settings}"
      curl --fail-with-body --silent --show-error -X PATCH \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${github_repository.highlight_js.full_name}/copilot/code-review/settings" \
        -d '{"review_effort":"lite"}'
    EOT
  }
}
