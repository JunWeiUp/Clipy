#!/usr/bin/env bash
# Offline guard for the macOS screenshot replacement. It detects known imported
# source blobs and conservatively rejects the entire legacy Screenshot tree.
# A passing result is evidence about build inputs, not a legal originality opinion.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'Screenshot provenance check: %s\n' "$*" >&2; exit 1; }

for required in git grep find; do
  command -v "$required" >/dev/null 2>&1 || fail "missing required command: $required"
done
for required in build_macos_app.sh LICENSE THIRD_PARTY_NOTICES.md README.md README_ZH.md docs/DEVELOPMENT.md; do
  [[ -f "$REPO_ROOT/$required" ]] || fail "missing release input: $required"
done

# build_macos_app.sh copies Sources and compiles every Swift file recursively.
# Fail closed if that contract changes, since the scan below would need updating.
# shellcheck disable=SC2016
grep -Fq 'cp -R "${MACOS_PROJECT_DIR}/Sources" "${BUILD_DIR}/Sources"' "$REPO_ROOT/build_macos_app.sh" ||
  fail 'build_macos_app.sh no longer copies the complete Sources tree; update this guard'
# shellcheck disable=SC2016
grep -Fq 'find "${BUILD_DIR}/Sources" -type f -name '\''*.swift'\''' "$REPO_ROOT/build_macos_app.sh" ||
  fail 'build_macos_app.sh no longer compiles every Swift source recursively; update this guard'
# shellcheck disable=SC2016
grep -Fq 'cp "${REPO_ROOT}/LICENSE" "${REPO_ROOT}/THIRD_PARTY_NOTICES.md"' "$REPO_ROOT/build_macos_app.sh" ||
  fail 'macOS bundle no longer includes LICENSE and THIRD_PARTY_NOTICES.md'

# Git blob IDs come from import commit 736ba8f and the audited pre-replacement
# tree. This catches byte-identical copies moved to a different source directory.
# Edited descendants need human provenance review; the legacy path ban below
# prevents the known imported tree from compiling even after local edits.
LEGACY_GIT_BLOBS='0af380e507af4ae9baa9c265aa642df95006eeb3
0ba5bef245286463af6c0fc0e6c5f008b2458883
0ef39f494ac8e2ba7d5e79561be51cedaeda6427
0f780df519eb5615967bb32a055abaa7b1eb7ea2
13eac5973202784e472f33bc919a82c8c9f00758
1534acaa7c581a1173b2b2e59caf73d9521805c6
153d207df94992a7d6480b08719d6cdc2377e8bf
158455ca6d98625ab0eedd0906802ae045fe03a6
162b0b461294e1f0e9687ad79f6d36d45ca470d2
1713683c7bc8701bea138ea8f0c26f03e938af2f
2697d11644428b3473f0b600aa79b0c72f003dfb
26dd56b0d686e001ab9bb7869ddb93e3201f8993
2761cc94d7c52b5fd4a5b361f0f6f5b09d42686c
2ab577a44d10554613e4e8f5c29ee2c9e148004e
2dcaf987aa40b6af74d1aec56376cd3886337b53
2e2e62d723e583cde6c7ac99fa6254b3fe452d30
31062bf1a9705d960215c67081e69a4314732195
31213e447a2d324a1660fa63984655a29e562048
32a223c9f656bbf462050f8666f4ab6ac1b07fe3
347bff5d0e9c786419d462f0b2a5d51334efc7d6
34ae00de309f28796d66c4016fe3b0134de7222d
3ad9ac903520b42da160ae1262ff27ff426f82a2
3e24e9690d5beeefa0a7908611ee11acf2ee8a8b
3f788bc5a66ca988f8190737fea9ebab055f0c8c
3f85babcce61ab605e0b4b01756d1a2c4107b598
46312b9ac076d3127a1613e7939674c979bdcb29
47322c629e13d4b5ba164ba67db18841aab1217a
4836b785ab7a91f358b5bec244889a5fe4092217
488371ae3901e6d7e476e0e46eca3bc386c64129
4a4fa9eebf0711ffcd5d571f09f694be0b6c1aa8
4ab0b768e4c246b13f34aefe86463f8bbb95761d
4bbd4f4ea9acd62809c4fc151a38d56bb56d8287
4bc413321e0d5f35c507fedcfc8e1605e95dc9e3
4e48873204c344e74dbe9e4fddde017e39a9b053
5166b0ac4c2ebd63f48ffc34fd959e6c70b132be
52128337671772cace80154f1abb55128e992bf5
532fe6ffcef5f9f5315aaab73282e750d6deea3d
53d7d9c6eb4e6f7281de5d93e61becc10ea3bb5f
5733bb03eb0ee8262252673f9aac106830faf9f6
58051e0f7483961f780c7bdb0439b2f593e6efb4
5b1bdfc7c988027d5b0d84ab1f55c08159d78b4e
5bd396cc3bbf550119cb6b1765f9da8a94de6f07
66e44d94d466b7389c1492f50651ad4933c05ab5
68708cb5ae3015686be320ab03c26877c687559c
692b8a8c86657ccf9509dcc0d99f81733fdfb526
6dc512c1dbe4b23385acd89679935c2a40d5c050
6fa4467d248757d9c5305c0cf4307d011745c197
708143a08e8ca76d633117d78b3ae24e31853e30
711d9732279f8cecbf898e0f1ba6223f3bbe7da8
71748232c38a923fe68731a6fff4546663169ee9
71e875c893bfc16db59a62af0521617a76278f28
735b7123d19ce03107b98c4ba8fdd955267135d8
74ee6701e3b5c63bb571b6467384839db46484a9
760b8f8a3f4a35527a09ce61b4becff9a0a11cf9
77c5ef9ebf45d98a5cea9a8ef819af76e08468d2
7c6a452124b8e6b3fbcba8ca3b27f0ff20e62e6b
7e17d89bdf723f459f2cf7aafcc40ac406f2ae7e
83ab5d5935d0e204cbf81b2c011ee3a92f4c43e2
85cf9da6f546e3e2f632cc4178e03035a6ea852d
89865b6c8b1f980d05a5dd6a06fea72efd96fde0
8aa1816764ba175b4979eb334a6484414de4e827
8d2dbf2cc2deb543a46f1da53f80b18bbbd51a83
8e8908b4e486529f03ac4caf05e69d8736260da7
9748e314d90dbc5478c73728f17ce2501d1d4175
98a9cf3fa723f38115d40c59393729bd47669b71
9cfc50880e658b92f8e32ddb9acd5ef794315545
9d57c3eb1c7e15b9b24d2d98469ba38b3eb36161
a0d74f230e25e82662caef6f8dafed47a0a76fb3
a3cd3f324e0daf433524969078401084b9ea47af
a5dfd89bda9b4f389cd18ab35dc4a634143a8d1e
a5e260f2be34f0405f4c317a21d099d774fceeac
a76986b06ad5718bbc8be7987377ffa6c7dec665
a7787464c8288fd3417ff014653bb9cacf0d7ace
a9433a30b75ad0fa7cb15f57350158694e337a8a
ac08715060ba754cc26694b9d1b533baeddd71c6
ad0cb49ba7f41c990a216a2ff8f2bbcaeaca5deb
b251abf92c6002cb90f43f71c9a7f6b1befb1857
b33ce1259d2b76aec9bbaab27d23b4e62b738b58
b3f5d20d9932b538644f6238cf6f5a883b86d4dd
b45c3aa70e33893da8e4f1c01d9e07063bebacdd
b52f250719955c76f661dfc0af65920e988aeab8
b8421dadba65485d15b02affb30c127f0c3188fe
b8bfb2c50fb8b226db84d044c245c7899640abbb
bd32fd73004c35438e66126d2489ae34b9742b1b
be52761a6122bc5f8002bd0c06a78be4e93a88d7
c02ccca3f9b7c2e09496f41d4b6f3a60f6bdc347
c0a2afb2afcc88db215e24b449442ee259f236dc
c14acae87d6d7e9fbdee5dc5bd74a935899ad118
c1bcf83262b82839af95a4a3c67173a873cf3f24
c2839a96e74acecfc1fdb51e275018a11f0e0a7c
c30f79ddbbac86005c814de72f003513952ccc2c
c6e482294f2c9ed5269f596262da82d1f1bd7d19
c701e733f5a2c412549c7de7ee4edc22bbc3c8b4
c934f50490a635eb66d4f0ef9c0ee7f10a2ebe80
cb648d717f8ca6eb7ced37c4fc05ef08489d0397
cef66b38a14537027c6d966080d443a84dd104dc
cfeaa511e1f1c38437a7fb81431734b3f2defe7e
d5e1b3725d3e02b38188067a4b02cd9c7afc16bd
d751f1311116b0cff54e08e1233d73402b708caf
d97fa4f9f52b4e933eb80a837122a80e83fd4c47
dbb039db7a3b8989166aa013dfca4c28a7a44af3
dd7fe48103663b88157bae33ef4e4e736218d7ed
dd8664492051e52f173ddaf778d27c75bfdbb9d4
dfebc5d3e909b8fcc94ae71e518cd703188929c0
e09a349ddee8252994e4c131372bb43ebf11f634
e12dc83ddbbfdf890ebf8ceb943041c0fdfda1f4
e2cd417f1206de59cd6543ce0c6b3793b6c0d62d
e3daaf66ce3a2c1df5242de069edd153c0bc781b
e48af8cd2b58271c304c7fe953879f494023055e
e54e579d45f525e411bd8c64f345123379b80ae9
e6c6c29567c64f44e941ed5883e580c5e58a9aff
e799df19429719e696ffdd039a664264500ae23e
e890c3753d0f7aa7e19a5cc00f8b296f80c75b08
e9f96145ead59b147c854f84f8990a976a75a2d5
ea83b4435c6b6ce1c043c3ba85b8b6f3dd876847
ed844b1d0a7469c6b0695d271daebc878cc935f9
ef8a2713d743a273480163556892d37aa5937e54
f4626e9b83064bdc90485d41058da027bdf20599
f6349f8d245c5e075539d5c797851cb8e2cbdf75
f687530b5ee9d1836c8067d556e18a11424df579
f7059261b0f3acc369a455e6d52ad314b57c284d
ffbfbdee784fe53a0206c3b7c10a90b09e1cf853'

source_count=0
while IFS= read -r -d '' source_file; do
  source_count=$((source_count + 1))
  relative="${source_file#"${REPO_ROOT}/"}"
  if [[ "$relative" == clipy_macos/Sources/Screenshot/* ]]; then
    fail "legacy imported source is still a macOS build input: $relative"
  fi
  blob_id="$(git hash-object --no-filters -- "$source_file")"
  if grep -Fqx -- "$blob_id" <<< "$LEGACY_GIT_BLOBS"; then
    fail "source has byte-identical content to the macshot import: $relative ($blob_id)"
  fi
  if grep -Fqi 'macshot' "$source_file"; then
    fail "source still refers to macshot; inspect and remove the old integration: $relative"
  fi
done < <(find "$REPO_ROOT/clipy_macos/Sources" -type f -name '*.swift' -print0)
[[ "$source_count" -gt 0 ]] || fail 'no macOS Swift sources found'

first_license_line="$(head -n 1 "$REPO_ROOT/LICENSE")"
[[ "$first_license_line" == 'MIT License' ]] ||
  fail 'LICENSE does not start with the declared MIT License'
notice="$REPO_ROOT/THIRD_PARTY_NOTICES.md"
grep -Fq 'Screenshot module provenance: independently implemented by Clipy contributors.' "$notice" ||
  fail 'THIRD_PARTY_NOTICES.md needs the reviewed independent-screenshot provenance statement'

# These phrases asserted that the current release still embeds the GPL port.
# Historical attribution is fine, but current-version claims must be updated.
for document in THIRD_PARTY_NOTICES.md README.md README_ZH.md docs/DEVELOPMENT.md; do
  path="$REPO_ROOT/$document"
  if grep -Eiq 'macshot-derived|ported from.*macshot|modified port of|release-blocking license review|blocking macshot license|macshot.*needs.*license|移植自.*macshot|macshot.*许可核对' "$path"; then
    fail "stale GPL-port or unresolved-license claim in $document"
  fi
done

printf 'Screenshot provenance check passed: %s macOS Swift build inputs; no legacy path/blob detected; release notices present.\n' "$source_count"
