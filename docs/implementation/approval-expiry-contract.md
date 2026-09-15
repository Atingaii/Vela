# Approval expiry / 审批有效期

New approvals on the development branch expire after seven days. The deadline is fixed when the request is created. Expiry prevents a pending action from starting; it does not cancel an action that already started, erase its evidence, or retry an uncertain result. This is not included in the preview.2 download.

开发分支的新审批默认七天有效，创建时确定截止时间。到期后尚未执行的动作不能再启动；已开始或结果不确定的动作不会因此被取消、删除或重试。公开 preview.2 下载不包含此功能。

```sh
# Inspect or change the policy for future requests in an explicitly selected Store.
vela call settings.get '{}' --home /absolute/path/to/store
vela call settings.save '{"approvalExpirySeconds":604800}' --home /absolute/path/to/store

# Read a request or an oldest-first page of pending requests.
vela call approvals.get '{"id":"approval-id"}' --home /absolute/path/to/store
vela call approvals.list '{"project":"/absolute/project","limit":50}' --home /absolute/path/to/store
vela call approvals.list '{"project":"/absolute/project","state":"expired","limit":50}' --home /absolute/path/to/store
```

The policy accepts integer-valued JSON numbers from `0` to `31536000` seconds. `0` explicitly disables expiry for future requests, whose `expiryMode` is `disabled`. Existing requests retain their original deadline. Requests created by an older helper without a deadline remain `legacy_unbounded`; upgrading does not invent a deadline or revoke them retroactively.

设置接受 `0...31536000` 秒范围的整数值；布尔值、字符串、分数和越界值均拒绝。`0` 明确关闭以后新请求的有效期，标记为 `disabled`。修改设置不改变已创建请求的截止时间。旧 helper 创建的无期限请求保持 `legacy_unbounded`，升级不会追溯撤销它们。

`approvals.get` returns one record. `approvals.list` returns `{items, cursor, order, state}`; pass the returned cursor unchanged for the next page. Ordering is creation time, then ID, ascending. Both calls may persist an elapsed request as `expired`, together with its linked run, step and business record. They do not run tools. An expired child stops its parent composition, including an optional child. Expired work is counted separately from workflow execution failures.

`get` 返回单条记录，`list` 返回 `{items, cursor, order, state}`，将返回的 cursor 原样用于下一页。按创建时间、ID 升序排列。这两个入口可能将到期请求及关联运行、步骤和业务记录持久化为 `expired`，但不运行工具；组合中的可选子任务到期也会停止父流程。过期记录与执行失败分别计数。

The explicit expired view projects at most 200 due requests per call and reports `expiredProjection.mayHaveMore`. When it is true, repeat that expired query until projection finishes, then restart pagination from the first page. No records are deleted. The approval decision itself always rechecks the deadline after acquiring the SQLite write lock, so a request cannot become executable while waiting behind another writer. An expired decision returns an error after expiry is persisted; callers must inspect the record and create a new request if they still want the action.

到期列表每次最多处理 200 个已到期请求，并返回 `expiredProjection.mayHaveMore`。为 true 时重复同一到期查询直到投影完成，再从第一页读取完整分页。此过程不删除记录。实际批准会在取得 SQLite 写锁之后再次核对截止时间；等待锁不会延长有效期。过期决定在保存终态后返回明确错误，若仍需执行，应重新创建并审阅请求。

The policy and paged ledger currently use Core/CLI APIs. A dedicated desktop deadline control, retention deletion policy and expiry notifications are separate work. See [ADR 0045](../adr/0045-bounded-approval-expiry.md).

有效期设置和分页账本当前通过 Core/CLI 使用。桌面专用设置、到期通知和按保留期删除数据属于另行实现的范围。架构决策见 [ADR 0045](../adr/0045-bounded-approval-expiry.md)。
