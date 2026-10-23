# Local development, CI and monitoring for Duman Messenger.
#
# Everything here is a thin front end onto tool/ci/, which is where the actual commands
# live. The split matters: `make ci` and `.github/workflows/ci.yml` run the same commands
# because tool/ci/run-pipeline.sh copies them from the workflow, not because two people
# wrote the same thing twice and hoped.
#
#   make doctor    is this machine able to verify this repository?
#   make ci        run the whole CI pipeline locally
#   make push      run the pipeline, and push only if it passed
#   make watch     what did the remote CI do?
#
# `make help` lists every target with its description.

SHELL := /bin/bash
CI    := ./tool/ci

.DEFAULT_GOAL := help
.PHONY: help doctor install ci ci-fast web dart cli-matrix probes \
        test typecheck build golden dev media history \
        dart-get dart-analyze dart-test dart-cli \
        push push-dry push-force commit-push watch watch-all follow diagnose \
        act install-hooks clean clean-artifacts

## --- setup -------------------------------------------------------------------

help: ## Show this help
	@printf '\n%s\n\n' "Duman Messenger — local development and CI"
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n%s\n' "Pipeline exit codes: 0 verified · 1 failed or incomplete · 2 partial"
	@printf '%s\n\n' "Docs: docs/10-local-development-and-ci.md"

doctor: ## Check this machine against the toolchain CI actually pins
	@$(CI)/doctor.sh

install: ## Install both toolchains' dependencies (npm ci + dart pub get)
	@npm ci --no-audit --no-fund
	@if command -v dart >/dev/null 2>&1; then \
	   (cd sim/mesh_sim && dart pub get); \
	 else \
	   printf '\033[33mwarning:\033[0m dart is not installed — skipped sim/mesh_sim. Run make doctor.\n'; \
	 fi

install-hooks: ## Install the pre-push hook (fast pipeline gate before every push)
	@git config core.hooksPath .githooks
	@chmod +x .githooks/* 2>/dev/null || true
	@printf 'installed: .githooks/ is now core.hooksPath\n'
	@printf 'bypass once with: git push --no-verify\n'

## --- the pipeline ------------------------------------------------------------

ci: ## Run every CI job locally (web, dart, cli-matrix, probes)
	@$(CI)/run-pipeline.sh

ci-fast: ## Quick subset: typecheck, unit tests, dart analyze, dart test
	@$(CI)/run-pipeline.sh --fast --keep-going

web: ## TypeScript engine + React simulator (the workflow's `web` job)
	@$(CI)/run-pipeline.sh --job web

dart: ## Dart authoritative engine: analyze + test + CLI acceptance, then gate
	@$(CI)/run-pipeline.sh --job dart

cli-matrix: ## CLI acceptance across all four scenarios and both power models
	@$(CI)/run-pipeline.sh --job cli-matrix

probes: ## CLI probes: SOS, groups, history anti-entropy, media
	@$(CI)/run-pipeline.sh --job probes

## --- push, gated -------------------------------------------------------------

push: ## Validate with the full pipeline, then push (refuses on red or partial)
	@$(CI)/validate-and-push.sh

push-dry: ## Everything push does, except the push itself
	@$(CI)/validate-and-push.sh --dry-run

push-force: ## Push after a PARTIAL run, and record that it was partial
	@$(CI)/validate-and-push.sh --force-partial

commit-push: ## Commit everything with MSG="...", validate, then push
	@test -n "$(MSG)" || { printf '\033[31merror:\033[0m usage: make commit-push MSG="fix: ..."\n'; exit 64; }
	@$(CI)/validate-and-push.sh --message "$(MSG)"

## --- monitoring --------------------------------------------------------------

watch: ## Recent CI runs on this branch
	@$(CI)/watch.sh

watch-all: ## Recent CI runs on every branch
	@$(CI)/watch.sh --all

follow: ## Wait for the newest run to finish, then explain the result
	@$(CI)/watch.sh --follow

diagnose: ## Jobs + annotations for a run (RUN=12345, default newest), and why it failed
	@$(CI)/watch.sh --diagnose $(RUN)

act: ## Run the real workflow YAML in Docker via act (JOB=dart to pick one)
	@command -v act >/dev/null 2>&1 || { printf '\033[31merror:\033[0m act is not installed (needs Docker). brew install act\n'; exit 64; }
ifdef JOB
	act push -j $(JOB)
else
	act push
endif

## --- individual checks -------------------------------------------------------

typecheck: ## tsc --noEmit on the app config
	@npx tsc --noEmit -p tsconfig.json

test: ## The TypeScript suite (vitest run)
	@npm test

build: ## Production build (tsc -b && vite build)
	@npm run build

golden: ## Regenerate the cross-language golden vectors and show the diff
	@npm run golden
	@git diff --stat -- test-fixtures/golden-vectors.json || true
	@printf '\nIf that diff is empty the vectors are up to date. If not, inspect it and commit.\n'

dev: ## The React visualiser (ALLOW_ANY_DEV_HOST=1 so a proxied preview host is accepted)
	@ALLOW_ANY_DEV_HOST=1 npm run dev

media: ## The media/radio probe. SECT=captureEffect to run one section
	@npm run media $(if $(SECT),-- $(SECT),)

history: ## Group-history anti-entropy probe (docs/06 §17)
	@npm run history

dart-get: ## dart pub get
	@cd sim/mesh_sim && dart pub get

dart-analyze: ## dart analyze (errors and warnings fail; infos do not)
	@cd sim/mesh_sim && dart analyze

dart-test: ## dart test with the expanded reporter
	@cd sim/mesh_sim && dart test --reporter expanded

dart-cli: ## The gated CLI acceptance run (campus_quad, seed 42)
	@cd sim/mesh_sim && dart run bin/mesh_sim.dart --scenario campus_quad --seed 42

## --- housekeeping ------------------------------------------------------------

clean: clean-artifacts ## Remove build output and CI artifacts
	@rm -rf dist tool/.build
	@printf 'cleaned dist/ and tool/.build/\n'

clean-artifacts: ## Remove captured CI run artifacts
	@rm -rf artifacts/ci
	@printf 'cleaned artifacts/ci/\n'
