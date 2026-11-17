# 用法见 make help；步骤名来自 install.sh 的步骤表
SHELL := /bin/bash
SUDO  := $(if $(filter 0,$(shell id -u)),,sudo)
RUN   := $(SUDO) ./install.sh
STEP_NAMES := $(shell ./install.sh --names)
STEPS ?= all
YES   := $(if $(filter yes,$(CONFIRM)),--yes)

# `make uninstall swap` 会被 make 拆成「卸载全部」+「安装 swap」，直接拒绝
ifneq ($(filter uninstall purge,$(MAKECMDGOALS)),)
ifneq ($(filter install stage1 stage2 stage3 $(STEP_NAMES),$(MAKECMDGOALS)),)
$(error 卸载/清除指定步骤请用 STEPS="swap ssh" 或 uninstall-<步骤>/purge-<步骤>)
endif
endif

.DEFAULT_GOAL := help
.PHONY: help list install uninstall purge stage1 stage2 stage3 test passwords credentials status backup-now \
	$(STEP_NAMES) $(addprefix uninstall-,$(STEP_NAMES)) $(addprefix purge-,$(STEP_NAMES))

help:
	@echo '安装:'
	@echo '  make install                    阶段 1、2（基础环境）'
	@echo '  make stage1 | stage2 | stage3   单个阶段；stage3 为全部可选组件'
	@echo '  make swap ssh ...               一个或多个步骤（按命令行顺序）'
	@echo '  make redis postgres otel ...    可选组件按需装'
	@echo '  make install STEPS="swap ssh"   多个步骤（按步骤表顺序）'
	@echo '卸载（撤销配置、停服务，保留数据）:'
	@echo '  make uninstall [STEPS=...]      默认全部（含组件），逆序执行'
	@echo '  make uninstall-<步骤>'
	@echo '清除（卸载并删除数据，不可恢复）:'
	@echo '  make purge [STEPS=...]          默认全部'
	@echo '  make purge-<步骤>'
	@echo '  非交互执行加 CONFIRM=yes'
	@echo '账号密码（统一在 /opt/base/credentials.env，可在安装前手填）:'
	@echo '  make passwords [STEPS=...]      预生成，已有的不覆盖'
	@echo '  make credentials                 显示账号密码文件位置及其中的变量名'
	@echo '  make rotate-password-<组件>     换新密码并立即生效，如 rotate-password-redis'
	@echo '运维:'
	@echo '  make status                     组件/证书/备份/磁盘一览'
	@echo '  make backup-now                 立即备份一次（make backup 启用每日定时备份）'
	@echo '  make restore-<组件> [BACKUP=<备份名>]  从备份恢复，默认最新一份，如 restore-postgres'
	@echo '其他: make list | make test'
	@echo
	@echo '步骤: $(STEP_NAMES)'

list:
	@./install.sh --list

install:
	$(RUN) install $(STEPS)

stage1 stage2 stage3:
	$(RUN) install $(@:stage%=%)

$(STEP_NAMES):
	$(RUN) install $@

uninstall:
	$(RUN) uninstall $(STEPS) $(YES)

$(addprefix uninstall-,$(STEP_NAMES)):
	$(RUN) uninstall $(@:uninstall-%=%) $(YES)

purge:
	$(RUN) purge $(STEPS) $(YES)

$(addprefix purge-,$(STEP_NAMES)):
	$(RUN) purge $(@:purge-%=%) $(YES)

passwords:
	$(RUN) passwords $(STEPS)

credentials:
	@$(RUN) credentials

rotate-password-%:
	$(RUN) rotate $* $(YES)

status:
	@$(RUN) status

backup-now:
	$(RUN) backup-run

restore-%:
	$(RUN) restore $* $(BACKUP) $(YES)

test:
	bash tests/run.sh
