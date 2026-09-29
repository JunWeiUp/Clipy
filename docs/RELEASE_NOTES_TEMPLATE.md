# Release notes template

Prepare this before triggering the **public Release** workflow. Follow the [release checklist](DEVELOPMENT.md#release-checklist), signing requirements and [macOS GPLv3 distribution terms](../THIRD_PARTY_NOTICES.md).

Replace every placeholder with verified information before publishing. Describe changes present in the tagged version, not changes that only exist on the development branch.

```markdown
## What's changed

- [User-visible change, the affected platform, and the problem it solves.]
- [Second meaningful change, if applicable.]

## Downloads

| Platform | File | Requirements |
| --- | --- | --- |
| macOS | [Link to the actual release asset] | [Verified OS minimum and architectures] |
| Android arm64 | [Link to the actual release asset] | [Verified ABI] |
| Windows x64 | [Link to the actual release asset] | Windows 10/11 |

## Upgrading

[Any setting migration, device reauthorization, data backup, or restart steps.]

## Known limitations

[Limitations relevant to this version, with links to the applicable documentation.]

## Licenses and source

The macOS package includes modified macshot code and is distributed under [GPLv3](../LICENSE.GPL-3.0). Clipy-authored code retains [MIT](../LICENSE). Link the corresponding source archive for this exact release tag and the [third-party notices](../THIRD_PARTY_NOTICES.md).

## 中文更新说明

- [对应的用户可见变化。]
- [升级步骤与本版本限制。]

**Full changelog:** [Previous tag...this tag]
```

After publication, update the pinned download URLs and version labels in both READMEs and both `GETTING_STARTED` guides. Confirm that each link matches one of the three uploaded packages. GitHub also provides two automatic source-code archives. Keep older release notes scoped to their own version.
