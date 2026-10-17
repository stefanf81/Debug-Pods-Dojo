.PHONY: up down status reset reset-lab check solve validate lint e2e command-e2e
up:
	./scripts/up.sh
down:
	./scripts/down.sh
status:
	./scripts/status.sh
reset:
	./scripts/reset-all.sh
reset-lab:
	@test -n "$(LAB)" || (echo "Usage: make reset-lab LAB=07" && exit 2)
	./scripts/reset-lab.sh "$(LAB)"
check:
	@test -n "$(LAB)" || (echo "Usage: make check LAB=07" && exit 2)
	./scripts/check-lab.sh "$(LAB)"
solve:
	@test -n "$(LAB)" || (echo "Usage: make solve LAB=07" && exit 2)
	./scripts/solve-lab.sh "$(LAB)"
validate:
	./scripts/validate.sh
lint:
	shellcheck -S warning scripts/*.sh
e2e:
	./scripts/e2e-test.sh

command-e2e:
	./scripts/command-e2e-test.sh
