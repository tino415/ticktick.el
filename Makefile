EMACS ?= emacs
PACKAGE = ticktick.el

.PHONY: all test compile checkdoc lint clean

all: lint test

## Run the ERT suite against recorded API responses (needs WireMock).
test:
	./tests/run-tests.sh

## Byte-compile; must be warning-free for melpazoid.
compile:
	$(EMACS) -Q --batch -f package-initialize -L . -f batch-byte-compile $(PACKAGE)
	@rm -f $(PACKAGE)c

## Docstring conventions.
checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote checkdoc)) (checkdoc-file "$(PACKAGE)"))'

lint: compile checkdoc

clean:
	rm -f *.elc
