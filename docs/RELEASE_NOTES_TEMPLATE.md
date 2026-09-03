# Release notes template

Use this for a **reviewed release draft**. The existing [release checklist](DEVELOPMENT.md#release-checklist), signing requirements, and [license review](../THIRD_PARTY_NOTICES.md) still apply.

Replace every placeholder with verified information before publishing. Describe changes present in the tagged version, not changes that only exist on the development branch.

```markdown
## What's changed

- [User-visible change, the affected platform, and the problem it solves.]
- [Second meaningful change, if applicable.]

## Downloads

| Platform | File | Requirements |
| --- | --- | --- |
| macOS | [Link to the actual release asset] | [Verified OS minimum and architectures] |
| Android | [Link to the actual release asset] | [Verified ABI] |

## Upgrading

[Any setting migration, device reauthorization, data backup, or restart steps.]

## Known limitations

[Limitations relevant to this version, with links to the applicable documentation.]

## 中文更新说明

- [对应的用户可见变化。]
- [升级步骤与本版本限制。]

**Full changelog:** [Previous tag...this tag]
```

After publishing a reviewed release, update the pinned download URLs and version labels in both READMEs and both `GETTING_STARTED` guides. Confirm that each link matches a real release asset. Keep older release notes scoped to their own version.
