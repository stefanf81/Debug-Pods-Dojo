.PHONY: up down status reset validate check e2e command-e2e
up:
	./scripts/up.sh
down:
	./scripts/down.sh
status:
	./scripts/status.sh
reset:
	./scripts/reset-all.sh
validate:
	./scripts/validate.sh
check:
	@test -n "$(LAB)" || (echo "Usage: make check LAB=07" && exit 2)
	./scripts/check-lab.sh "$(LAB)"
e2e:
	./scripts/e2e-test.sh

command-e2e:
	./scripts/command-e2e-test.sh
