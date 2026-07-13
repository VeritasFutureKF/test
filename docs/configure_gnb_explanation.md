# `configure_gnb.sh` 脚本详解

本文逐段说明 `scripts/configure_gnb.sh` 的作用、交互流程以及各函数负责的配置内容，帮助理解脚本如何为虚拟化的 gNB（5G 基站）完成参数初始化。

## 脚本定位与总体流程

脚本通过 `rgcli` 命令行工具对运行在 Docker 容器或 Kubernetes Pod 中的 vCU（集中单元）发出配置命令【F:scripts/configure_gnb.sh†L227-L250】。它会：

1. 解析 `-k`（切换至 Kubernetes 模式）与 `-v`（打印命令）等命令行参数。【F:scripts/configure_gnb.sh†L545-L567】
2. 确认目标容器/Pod 存在并征询用户是否继续。【F:scripts/configure_gnb.sh†L576-L602】
3. 按顺序调用一系列交互式函数，逐步完成运营商、AMF、NR 小区、切片、安全等配置，最后激活小区并查看噪声状态。【F:scripts/configure_gnb.sh†L604-L641】

所有配置命令都通过 `exec_rgcli` 封装函数下发，可根据 Docker 或 Kubernetes 环境决定命令格式，并在 `-v` 开启时打印具体命令行。【F:scripts/configure_gnb.sh†L227-L250】

## 参数校验与输入函数

脚本包含多个输入辅助函数，负责确保用户输入合法：

* `check_string_not_empty`：校验字符串非空，用于检测必需参数，例如容器名称。【F:scripts/configure_gnb.sh†L56-L69】
* `read_integer_in_range` / `check_integer_range`：循环读取并验证整数是否在给定区间内，支持默认值提示，常用于 gNB ID、频点、PCI、TAC 等参数。【F:scripts/configure_gnb.sh†L88-L154】
* `read_ipv4_addr`：确保输入的 IPv4 地址格式正确，必要时使用默认值；`get_ipv4_subnet` 则用来计算 AMF 网络的子网地址。【F:scripts/configure_gnb.sh†L156-L225】

通过这些函数，脚本能够在交互式配置时尽量避免输入错误导致的下发失败。

## 核心配置步骤

### 1. 账户与运营商信息

* `set_gnb_password`：按需调用 `rgcli` 修改 `opr` 与 `root` 用户密码。【F:scripts/configure_gnb.sh†L253-L265】
* `config_operators`：读取 gNB ID 与 PLMN，创建/更新 CU 与 DU 运营商条目，并确保两侧的 gNB ID 一致。【F:scripts/configure_gnb.sh†L268-L353】

### 2. 信令/承载网配置

* `config_amf_pool`：采集 AMF、NG 接口 IP 与网关信息，新增 AMF 池、NG 接口地址及默认路由。【F:scripts/configure_gnb.sh†L355-L371】

### 3. NR 小区参数

* `config_cu_du_cell`：输入 NR 频段、NRARFCN、PCI、TAC、收发模式等信息，分别创建 CU 侧 `nrcell` 与 DU 侧 `nrducell` 配置。【F:scripts/configure_gnb.sh†L373-L413】
* `config_slice`：按需定义网络切片 SST/SD，并关联到 nrDU Cell 的切片组中。【F:scripts/configure_gnb.sh†L415-L433】
* `config_rru`：设置 RRU 天线模式（内置/外接），并建立 RRU 相关的资源组、覆盖参数。【F:scripts/configure_gnb.sh†L435-L452】

### 4. 安全与性能

* `config_cipher`：启用 NEA1/NEA0 加密与 NIA1 完整性算法，同时打开用户面加密/完整性开关。【F:scripts/configure_gnb.sh†L454-L470】
* `config_inactive_timer`：根据用户选择关闭或设定 UE 不活动定时器值。【F:scripts/configure_gnb.sh†L472-L484】
* `config_csirs_trs`：控制 CSI-RS 资源的自适应与 TRS 周期，以调节参考信号行为。【F:scripts/configure_gnb.sh†L486-L497】
* `config_frame_offset`：展示并按需调整 gNB 的帧时偏移。【F:scripts/configure_gnb.sh†L518-L534】
* `check_cell_ul_noise`：查询小区上行噪声，帮助确认射频环境。【F:scripts/configure_gnb.sh†L536-L538】

### 5. 其它辅助

* `config_eweb_connection`：停止并禁用宿主机防火墙，为后续 eWeb 调试界面开放访问。【F:scripts/configure_gnb.sh†L512-L516】
* `activate_cell`：交互式决定是否立刻激活小区，并打印当前小区信息。【F:scripts/configure_gnb.sh†L499-L510】

## 交互式循环与多小区支持

脚本在完成主小区配置后，允许用户循环调用 `config_cu_du_cell`，以便为同一 gNB 添加更多小区。当用户选择“否”时跳出循环继续执行后续步骤。【F:scripts/configure_gnb.sh†L610-L621】

## 总结

`configure_gnb.sh` 通过一系列交互式提示、输入验证与封装好的 `rgcli` 命令，自动化完成 vCU 环境下 gNB 的常见配置步骤，涵盖运营商信息、核心网接口、NR 小区参数、切片、安全、射频以及系统偏移等关键设置。脚本即开即用，可在 Docker 与 Kubernetes 场景下复用，显著减少手工逐条敲命令的工作量。【F:scripts/configure_gnb.sh†L10-L641】
