EMACS ?= emacs

SOURCES = widgetry-core.el widgetry-slider.el widgetry-toggle.el widgetry-chips.el widgetry-buttons.el \
          widgetry-selector.el widgetry-vector.el widgetry-activity.el widgetry-button.el widgetry-link.el widgetry-secret.el widgetry-text.el widgetry-meter.el widgetry.el
TESTS = $(wildcard test/*-test.el)

.PHONY: test compile bench

test:
	$(EMACS) -Q --batch -L . -L test $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES)

bench:
	$(EMACS) -Q --batch -L . -l bench/bench.el
