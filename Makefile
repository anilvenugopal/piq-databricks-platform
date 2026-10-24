# Thin wrappers. A deployment target is a stack + a scope + (except for scope shared) an environment:
#   make plan STACK=40-unity-catalog ENV=dev SCOPE=domain:claims
#   make apply STACK=20-identity SCOPE=shared
# Scopes: shared | env | access | domain:<name>. See docs/CONCEPTS.md.
STACK ?= 10-foundation
SCOPE ?= env
ENV   ?=
ARGS   = $(STACK) --scope $(SCOPE) $(if $(ENV),--env $(ENV))

.PHONY: validate test plan-test fmt plan apply check status plan-all release

validate:            ## config checks + terraform fmt check
	python3 scripts/validate_config.py
	terraform fmt -recursive -check

test:               ## naming, validator and wrapper tests (no cloud access needed)
	python3 tests/naming/run_tests.py
	python3 tests/wrappers/run_tests.py

plan-test:          ## mocked plan of every stack for every target (needs provider downloads)
	python3 tests/stacks/run_plan_tests.py

fmt:
	terraform fmt -recursive

plan:               ## plan one target and run the scope check
	python3 scripts/plan.py $(ARGS)

apply:              ## plan, confirm, apply, check and record one target
	python3 scripts/apply.py $(ARGS)

check:              ## run the post-apply checks of one target
	python3 scripts/check.py $(ARGS)

plan-all:           ## plan every target of an environment (read-only): make plan-all ENV=dev
	python3 scripts/plan_all.py --env $(ENV)

status:             ## which release is deployed where
	python3 scripts/status.py $(if $(ENV),--env $(ENV))

release:            ## cut a release tag on the current commit
	python3 scripts/release.py
