# Walrus real-account acceptance preparation / 真实账户验收准备

2026-09-13。此文档是可审阅的执行准备。当前已授权本轮新建隔离 testnet key、使用官方免费 faucet 与公开查询；未授权使用已有钱包或真实币，未完成远端写入。

## 已确认的无账户信息

使用真实安装适配器仅查询 `/version`，mainnet 和 testnet 均返回 API `1.0.0`、relayer `0.1.0`，TS compatibility baseline `0.0.4`。这些请求 `authenticated:false`，没有读取已有 key/account、上传 Memory 或发链上交易。

公开 `/config` 在本次查询返回：

| 项目 | Mainnet | Testnet |
| --- | --- | --- |
| Relayer | `https://relayer.memory.walrus.xyz` | `https://relayer-staging.memory.walrus.xyz` |
| packageId | `0xe7c16fbea0560e7057e2bf7422feaa4fb313749fc69c9e9092fac7a33b81d7f5` | `0x0a625e2db2af6f591a4c80a3d8551ddf11656089cc3a20c5e9e7f8fb75b9265c` |
| advertised JSON-RPC | `https://rpc-mainnet.suiscan.xyz` | `https://sui-testnet-endpoint.blockvision.org` |
| advertised gRPC | `https://fullnode.mainnet.sui.io` | `https://fullnode.testnet.sui.io` |

这些仅为当次公开查询证据，不能自动采纳为用户已选择配置。每次 protected operation 重新核对冻结 profile 的 network/package，包含官方 SDK 内部 `/config` 重取。公开配置没有提供 registry ID、用户 account ID/owner、embedding 凭据、实际存储 epochs 或费用报价，不填虚构值。

## 还需用户明确选择的非秘密信息

本轮已明确采用新建隔离 testnet 身份；生产接入仍须由用户明确选择。准备 profile 需要：network/relayer/fullnode、匹配的初始 package 与当前 policy package、registry ID、新测试 owner 公钥地址、已有或将创建的 account ID、测试 namespace，以及允许的 SEAL/Walrus origins。需要外部 embedding 时还应明确 endpoint/model 与原文明文接收者。

不要求用户把私钥粘贴给代理。owner 通过其钱包对已冻结 transaction bytes 签名；delegate 可新生成并由用户的凭据保管层持有。当前 headless Manual SDK 的 Sui/delegate/embedding 凭据由调用应用显式注入，客户端 Keychain/wallet 界面尚需接入。代理不会自动查看当前 shell/provider/wallet 的凭据。

## Owner 交易的精确批准合同

1. `prepareOwnerAction` 仅接受 createAccount、addDelegate、removeDelegate 的明确参数，以及必填正整数 `maxGasBudgetMIST`。新增 delegate 需完整 public key 和 label；撤销需完整 public key。
2. 调用官方公开 account builder，在其公开 walletSigner 回调中截获未提交 Transaction。此步骤没有签名/执行，不调用 SDK 私有函数。
3. 用已选择真实节点解析 object refs 与 gas coin，设置精确 sender、Gas budget cap 和下一 epoch 的到期条件，生成完整 transaction bytes 与 digest。没有得到完整 bytes 的预览不能执行，不能拿一份尚待解析的 JSON 命令列表当最终批准。
4. 最终预览必须展示 operation、owner、network、registry/account、公钥/label、Gas cap（MIST）、epoch/time expiry、完整 bytes/hash/digest。上限不是实际费用报价。任何参数变化需重新 prepare。
5. 钱包对这组精确 bytes 签名，调用 `executeOwnerAction(preview, serializedSignature)`。在发送前使用官方 `verifyTransactionSignature` 核对 expected owner 与 bytes，消费本次批准后发送一次。SDK 不需要 owner 私钥。
6. 响应按真实 digest/effects 区分 submitted/succeeded/failed，实际 gasUsed 仅在节点有返回时显示；缺失为 null。创建账户的 object ID 缺失时继续按 digest 查询，不能填旧 ID 或自造 ID。
7. 响应不明/超时只用 `ownerTransactionStatus(digest)` 查询，不能自动重发创建/授权/撤销。交易已提交后 wallet/worker 关闭不意味着回滚。

## Remote memory 最小实网执行清单

只准备一条非敏感合成记忆：`Vela remote acceptance fixture: the automobile requires maintenance.`。记录用户选择的 namespace，不混用生产默认 namespace。`prepareRemember` 冻结整段文本、profile、明文接收者与 operation ID；写入次数上限 1、plaintext bytes 上限可精确设置为该字符串的实际 UTF-8 字节数。

当前官方 Manual relay method 不发送客户端 walrusEpochs，公开 `/config` 也无 storage/embedding 费用报价。预览保留 `storageEpochs:null`、`monetaryQuote:null`，说明上传由所选 relayer 管理。这不能被用户误看为免费、已限制期限或金额为零。如果需要精确金额硬上限，应先取得部署方可核对的 sponsored storage 条款或可执行报价；没有报价不能声称已配置费用上限。

授权后执行顺序：signed connect → reviewed remember → 已完成的 durable Blob/job 证据 → 关闭 helper → 全新本地 store 和相同明确身份下载解密 → 原文 SHA 相同 → candidate 导入 → 用户审核激活 → 实际语义召回。随后用独立新 delegate 测试授权/撤销，撤销后的新请求必须失败；历史已拿到的明文不会因撤销而消失。

服务端 `restoreIndexRelayer` 必须单独批准其原文处理范围。完整端侧 manifest 恢复另行测试 Blob 明确清单、分页断点、损坏密文、私有/项目隔离与集合摘要，不能因为一次 bounded restore 返回 `truncated:false` 就标为全部恢复。

## English summary

Public mainnet/testnet preflight succeeded without credentials or writes. The next acceptance run needs explicitly chosen test-account/deployment settings and storage terms. Owner actions freeze fully built transaction bytes, gas cap and expiry before wallet signature; the adapter verifies the exact owner signature and submits once. Missing fees, epochs, account IDs or effects remain unavailable. A real encrypted write, fresh-store decrypt, hash check and reviewed recall must pass before claiming remote round-trip completion.

## Isolated testnet preparation receipt / 隔离测试网准备回执

2026-09-13 的只读查询确认 `/config` 当前 testnet package 的发布交易为 `53QUaB3xiFhf1AXey5aWDMSpvm5yf2usudwSppxpyVZ8`，创建 registry `0x736aef9906798fca4460490ccdf8e8502ef170122dc26ecae32111b78c6b42dd`。对象 type 匹配该 package，链上 version 4，migration_finalized:true，shared 初始版本 941625040。旧文档里的 registry 并非当前 `/config` 配对，不能盲目复制。

本轮新 owner 公钥地址为 `0xd7bcad95e8bb28cd8e583de911bc5f316fc16d18568eb2424ac7e0079d6e249b`。只生成了新的隔离测试 key，未读取现有用户钱包。官方 `https://faucet.testnet.sui.io/v2/gas` 第一次申请明确返回 429（SDK FaucetRateLimitError），SDK 未暴露 Retry-After；随后公开 getBalance 返回 totalBalance:0、coinObjectCount:0。没有提交 owner 交易，也没有上传记忆。

计划每笔 owner 交易 gas cap 为 10,000,000 MIST（0.01 test SUI），整轮 owner create/add/remove 等测试资金预算为 100,000,000 MIST（0.1 test SUI）。这是测试预算与上限，不是实际 gas 报价或存储费用承诺。至少需足够覆盖选定 gas cap 的真实 testnet gas coin；余额为零时不能生成完整含 gas payment refs 的可执行交易。若免费 faucet 持续限流，只能等待其明确允许的重试窗口或由用户经官方测试网入口资助这个公开测试地址，不能使用真钱、非官方 faucet 或绕过限流。


第二次（本轮最后一次自动申请）官方 faucet 仍为 HTTP 429，返回 Retry-After:30；余额仍为 0。已停止继续申请。官方 [Web faucet](https://faucet.sui.io/) 提供 Your Wallet Address 输入与 Request Testnet SUI，亦见 [官方 SDK 指引](https://sdk.mystenlabs.com/sui)。只需填上面的公开测试地址，不需要提供私钥。

同日公开节点 devInspect 的 createAccount 模拟成功，computationCost=1,000,000、storageCost=7,121,200、storageRebate=2,212,056 MIST，净成本 5,909,144 MIST。此模拟没有提交交易，也不生成可执行 gas payment 对象。基于当前毛成本 8,121,200 MIST，首笔 10,000,000 MIST gas cap 有明确依据；最初 0.1 test SUI 只是十笔预留，并非最小需求。首轮 create/add/remove 三笔的资金预算调整为 **0.03 test SUI**（每笔最多 0.01），后续更多测试再另列计划。真实执行会重新构建、核对 cap 与实际 effects；模拟不保证未来费用不变。
