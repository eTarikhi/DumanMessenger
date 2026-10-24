# Local development, CI and monitoring for Duman Messenger.
#
# Everything here is a thin front end onto tool/ci/, which is where the actual commands
# live. The split matters: `make ci` and `.github/workflows/ci.yml` run the same commands
# because tool/ci/run-pipeline.sh copies them from the workflow, not because two people
# wrote the same thing twice and hoped.
#
#   make doctor    is this machine able to verify this repository?
#   make ci        run the whole CI pipeline locally
#   make checks    every check at once, one report, and which have never been run
#   make push      run the pipeline, and push only if it passed
#   make watch     what did the remote CI do?
#
# `make help` lists every target with its description.

SHELL := /bin/bash
CI    := ./tool/ci

.DEFAULT_GOAL := help
.PHONY: help doctor install ci ci-fast web dart cli-matrix probes \
        test typecheck build golden dev media history e2ee \
        dart-get dart-analyze dart-test dart-cli \
        push push-dry push-force commit-push watch watch-all follow diagnose \
        checks checks-list checks-evidence \
        pr pr-dry pr-open pr-local pr-branch pr-squash check-ps1 check-docs \
        dart-balance parity act install-hooks clean clean-artifacts

## --- setup -------------------------------------------------------------------

help: ## Show this help
	@printf '\n%s\n\n' "Duman Messenger — local development and CI"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n%s\n' "Pipeline exit codes: 0 verified · 1 failed or incomplete · 2 partial"
	@printf '%s\n'   "  Through make, 1 and 2 both arrive as 2 — that is make's own code for any"
	@printf '%s\n'   "  recipe failure. Call tool/ci/*.sh directly to tell them apart."
	@printf '%s\n'   "Docs: docs/10-local-development-and-ci.md  (pipeline, exit codes, monitoring)"
	@printf '%s\n'   "      docs/11-windows-11-workflow.md       (WSL2, Git Bash, make.ps1)"
	@printf '%s\n\n' "      docs/12-cli-cheat-sheet.md           (every command, by task)"

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

## --- every check at once -----------------------------------------------------
#
# `make ci` mirrors .github/workflows/ci.yml one command for one command, and that mapping is
# its whole value. `make checks` is deliberately a superset: everything CI runs, plus the
# checks that only make sense locally, plus a column CI cannot give you — which of these have
# never actually been run against this tree. It never stops at the first failure.

checks: ## Every check at once, one report; nothing stops at the first failure
	@$(CI)/collect-checks.sh

checks-list: ## What `make checks` would run, and which checks have never been run
	@$(CI)/collect-checks.sh --list

checks-evidence: ## `make checks` plus the slow probes that reproduce the docs' numbers
	@$(CI)/collect-checks.sh --with-evidence

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

## --- pull request ------------------------------------------------------------
#
# pr-flow.sh validates locally, pushes, opens the PR, then decides about merging.
# Local validation gates *opening* the PR; it does not by itself justify *merging*,
# because a local run is only as broad as the toolchain on this machine. --merge-on
# chooses what evidence the merge may rest on, and every outcome is logged.

pr: ## Validate, push, open a PR, merge only when the CI checks pass
	@$(CI)/pr-flow.sh

pr-dry: ## Every PR decision printed, with no side effects at all
	@$(CI)/pr-flow.sh --dry-run

pr-open: ## Open the PR and stop — leave the merge to a human
	@$(CI)/pr-flow.sh --merge-on never

pr-local: ## Merge on the local run alone; for when CI cannot run. Records that it did not
	@$(CI)/pr-flow.sh --merge-on local --yes

pr-branch: ## The whole flow on a new branch: make pr-branch BRANCH=fix/your-change
	@test -n "$(BRANCH)" || { printf '\033[31merror:\033[0m usage: make pr-branch BRANCH="fix/your-change"\n'; exit 64; }
	@$(CI)/pr-flow.sh --new-branch "$(BRANCH)"

pr-squash: ## Like pr, but squash-merge and delete the branch afterwards
	@$(CI)/pr-flow.sh --squash --delete-branch

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

e2ee: ## What E2EE costs on this mesh (docs/07 §2-§4, §7). SECT=latency|churn|packet|crypto
	@npm run e2ee $(if $(SECT),-- $(SECT),)

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
	@rm -rf dist tool/.build sim/mesh_sim/build
	@printf 'cleaned dist/, tool/.build/ and sim/mesh_sim/build/\n'

check-ps1: ## Static check of make.ps1, for machines that cannot run PowerShell
	@python3 $(CI)/check-ps1.py make.ps1

check-docs: ## Does every command the docs tell you to run actually exist?
	@python3 $(CI)/check-docs.py

# Not a substitute for `dart analyze`, which needs the SDK this target exists to
# work without. It answers one question about sim/mesh_sim — does every delimiter
# opened outside a comment or a string get closed — so that a brace mistake shows
# up here in one line instead of as a hundred analyzer errors on somebody else's
# machine. `--self-test` runs its own 19 cases, 12 of which must NOT alarm.
dart-balance: ## Do the Dart sources balance? Needs no Dart SDK
	@python3 $(CI)/check-dart-balance.py

# The two engines are a contract: same protocol constants, same golden vectors.
# `make golden` polices the TypeScript side and `dart test` the Dart one, and
# neither runs where there is no Dart SDK — which is everywhere in this pipeline
# right now. This compares the constants directly, in both directions of value, and
# needs nothing but python3.
parity: ## Do the two engines agree on their constants? Needs no toolchain
	@python3 $(CI)/check-parity.py

clean-artifacts: ## Remove captured CI run artifacts
	@rm -rf artifacts/ci
	@printf 'cleaned artifacts/ci/\n'
