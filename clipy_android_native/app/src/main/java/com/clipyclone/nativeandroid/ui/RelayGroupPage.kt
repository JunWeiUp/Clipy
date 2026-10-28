package com.clipyclone.nativeandroid.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.clipyclone.nativeandroid.relay.*
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private sealed interface GroupConfirmation {
    data class Remove(val member: RelayMember) : GroupConfirmation
    data class Exit(val disband: Boolean) : GroupConfirmation
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun RelayGroupPage(controller: NativeRelayController, back: () -> Unit, message: (String) -> Unit) {
    val state by controller.state.collectAsStateWithLifecycle()
    val zh = LocalStrings.current.chinese; val active = LocalPageActive.current
    val colors = MaterialTheme.colorScheme; val scope = rememberCoroutineScope(); val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    var creating by rememberSaveable { mutableStateOf(true) }; var upgrade by rememberSaveable { mutableStateOf(false) }
    var automatic by rememberSaveable { mutableStateOf(true) }; var grantManager by rememberSaveable { mutableStateOf(false) }
    var groupName by rememberSaveable { mutableStateOf("") }
    var name by rememberSaveable { mutableStateOf(runCatching { android.system.Os.uname().nodename }.getOrDefault("Android")) }
    var code by remember { mutableStateOf("") }; var rename by remember { mutableStateOf<RelayMember?>(null) }
    var renameValue by remember { mutableStateOf("") }; var renameInvalid by remember { mutableStateOf(false) }
    var confirmation by remember { mutableStateOf<GroupConfirmation?>(null) }
    val scanner = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) result.data?.getStringExtra("invitation")?.let {
            code = it; creating = false; scope.launch { controller.joinGroup(it, name) }
        }
    }
    DisposableEffect(controller, active) { controller.setGroupPageOpen(active); onDispose { controller.setGroupPageOpen(false) } }
    DisposableEffect(lifecycle, controller) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) controller.setForeground(true)
            else if (event == Lifecycle.Event.ON_PAUSE) controller.setForeground(false)
        }
        lifecycle.lifecycle.addObserver(observer)
        controller.setForeground(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(controller) { controller.refreshGroups() }
    LaunchedEffect(state.invitationLink) { grantManager = false }
    LaunchedEffect(state.draftGroupName, state.draftDeviceName, state.draftInvitation, state.creationPending) {
        if (state.creationPending) { creating = true; groupName = state.draftGroupName }
        if (state.draftDeviceName.isNotEmpty()) name = state.draftDeviceName
        if (code.isEmpty() && state.draftInvitation.isNotEmpty()) code = state.draftInvitation
    }
    LaunchedEffect(state.notice) {
        if (state.notice == RelayNotice.LEFT || state.notice == RelayNotice.DISBANDED) { code = ""; groupName = ""; creating = true; upgrade = false }
    }
    fun leave(disband: Boolean) {
        if (!disband && !state.revoked && state.canManage && state.members.size > 1 && state.members.count { it.manager } == 1) controller.notice(RelayNotice.LAST_MANAGER)
        else confirmation = GroupConfirmation.Exit(disband)
    }
    Scaffold(containerColor = colors.background, topBar = {
        SecondaryAppBar(relayText(zh, "公网设备组", "Relay device group"), back) {
            IconButton(onClick = { scope.launch { controller.refreshGroups() } }, enabled = !state.busy) { ClipyIcon(ClipyIcons.refresh, color = colors.onSurface, description = relayText(zh, "刷新", "Refresh")) }
        }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 720.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 20.dp, top = 16.dp, end = 20.dp, bottom = 32.dp)) {
                if (state.busy) { if (active) LinearProgressIndicator(Modifier.fillMaxWidth()); Spacer(Modifier.height(20.dp)) }
                state.notice?.let { notice ->
                    Text(groupNotice(zh, notice), Modifier.fillMaxWidth().background(colors.secondaryContainer, RoundedCornerShape(12.dp)).padding(16.dp))
                    Spacer(Modifier.height(20.dp))
                }
                when {
                    state.revoked -> GroupSection(relayText(zh, "设备组不可用", "Group unavailable"), relayText(zh,
                        "组可能已解散，或本机已被移除。旧名单不再代表当前成员，也不能用于添加设备。",
                        "The group may have been disbanded or this device removed. The saved roster is no longer current.")) {
                        RelayFilledButton(relayText(zh, "返回创建或加入", "Return to create or join"), !state.busy, modifier = Modifier.fillMaxWidth(), icon = ClipyIcons.logout) { leave(false) }
                    }
                    state.managed -> GroupSection(state.groupName.ifEmpty { state.groupId },
                        "${state.members.size} ${relayText(zh, "台设备", "devices")} · ${if (state.canManage) relayText(zh, "你是管理员", "You are a manager") else relayText(zh, "你是成员", "You are a member")}") {
                        state.members.forEach { member ->
                            GroupMember(member, state, zh, rename = { rename = member; renameValue = member.name; renameInvalid = false }, remove = { confirmation = GroupConfirmation.Remove(member) })
                            Spacer(Modifier.height(12.dp))
                        }
                        if (state.canManage && state.invitationLink.isEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            GroupSwitch(automatic, { automatic = it }, !state.busy, relayText(zh, "扫码后自动加入", "Join automatically after scanning"),
                                relayText(zh, "关闭后需核对配对码并手动批准。", "Turn off to compare pairing codes and approve manually."))
                            RelayFilledButton(relayText(zh, "添加设备", "Add device"), !state.busy, modifier = Modifier.fillMaxWidth(), icon = ClipyIcons.add) { scope.launch { controller.invite(automatic) } }
                        }
                        if (!state.canManage) Text(relayText(zh, "请联系管理员添加或移除设备。", "Ask a manager to add or remove devices."))
                    }
                    state.groupLoaded -> {
                        if (state.legacy) {
                            GroupLegacy(state, zh)
                            Spacer(Modifier.height(16.dp))
                            GroupOutlineButton(relayText(zh, "升级组管理配置", "Upgrade group management"), !state.busy, if (upgrade) ClipyIcons.expand_less else ClipyIcons.expand_more, modifier = Modifier.fillMaxWidth()) { upgrade = !upgrade }
                            Spacer(Modifier.height(20.dp))
                        } else if (!state.pending && !state.creationPending) {
                            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                                SegmentedButton(creating, { creating = true }, SegmentedButtonDefaults.itemShape(0, 2), enabled = !state.busy,
                                    icon = { ClipyButtonIcon(if (creating) ClipyIcons.check_rounded else ClipyIcons.add_circle_outline) }) { Text(relayText(zh, "创建新组", "Create group")) }
                                SegmentedButton(!creating, { creating = false }, SegmentedButtonDefaults.itemShape(1, 2), enabled = !state.busy,
                                    icon = { ClipyButtonIcon(if (!creating) ClipyIcons.check_rounded else ClipyIcons.group_add_outlined) }) { Text(relayText(zh, "加入已有组", "Join group")) }
                            }
                            Spacer(Modifier.height(24.dp))
                        }
                        if (!state.pending && (!state.legacy || upgrade)) {
                            val create = !state.legacy && creating
                            GroupSection(if (state.legacy) relayText(zh, "启用组管理", "Enable group management") else if (create) relayText(zh, "创建你的设备组", "Create your device group") else relayText(zh, "加入已有设备组", "Join an existing group"),
                                if (state.legacy) relayText(zh, "导入管理员提供的升级邀请，保留当前设备身份。", "Import an upgrade invitation from your manager to keep your device identity.")
                                else if (create) relayText(zh, "创建后，你就是管理员，可以邀请手机和电脑加入。", "You become the manager and can invite phones and computers.")
                                else relayText(zh, "在另一台设备上选择「添加设备」，然后扫描或粘贴邀请。", "Choose Add device on another device, then scan or paste its invitation.")) {
                                if (create) { RelayField(groupName, { groupName = it }, relayText(zh, "设备组名称", "Group name"), hint = relayText(zh, "例如：我的设备", "For example: My devices"), enabled = !state.busy && !state.creationPending); Spacer(Modifier.height(20.dp)) }
                                RelayField(name, { name = it }, relayText(zh, "本机名称", "Device name"), enabled = !state.busy && !state.creationPending)
                                Spacer(Modifier.height(20.dp))
                                if (create) {
                                    RelayFilledButton(if (state.creationPending) relayText(zh, "继续创建", "Continue creating") else relayText(zh, "创建设备组", "Create group"), !state.busy, modifier = Modifier.fillMaxWidth(), icon = ClipyIcons.add_circle_outline) {
                                        if (groupName.trim().isEmpty() || name.trim().isEmpty() || groupName.trim().toByteArray().size > 128 || name.trim().toByteArray().size > 128)
                                            controller.notice(RelayNotice.INVALID_GROUP_NAME)
                                        else scope.launch { controller.createGroup(groupName, name) }
                                    }
                                    if (state.creationPending) { Spacer(Modifier.height(12.dp)); Text(relayText(zh, "已保存创建进度。网络恢复后可继续，不会重复建组。", "Progress saved. Retry after reconnecting without creating a duplicate.")) }
                                } else {
                                    RelayField(code, { code = it }, relayText(zh, "邀请链接", "Invitation link"), enabled = !state.busy, lines = 3)
                                    Spacer(Modifier.height(24.dp))
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                        GroupOutlineButton(relayText(zh, "扫码加入", "Scan invitation"), !state.busy, ClipyIcons.qr_code_scanner) { scanner.launch(Intent(context, RelayScannerActivity::class.java).putExtra("chinese", zh)) }
                                        RelayFilledButton(if (state.legacy) relayText(zh, "升级当前组配置", "Upgrade current group") else relayText(zh, "申请加入", "Request to join"), !state.busy) { scope.launch { controller.joinGroup(code, name) } }
                                    }
                                }
                            }
                        }
                    }
                }
                if (state.managed && !state.revoked) {
                    Spacer(Modifier.height(24.dp))
                    GroupSection(relayText(zh, "离开设备组", "Leave this group"), relayText(zh, "退出仅影响本机；解散会撤销整个组的公网访问权限。", "Leaving affects this device. Disbanding revokes access for the entire group.")) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            GroupOutlineButton(relayText(zh, "退出当前组", "Leave group"), !state.busy, ClipyIcons.logout) { leave(false) }
                            if (state.canManage) TextButton(onClick = { leave(true) }, enabled = !state.busy, colors = ButtonDefaults.textButtonColors(contentColor = colors.error)) { ClipyIcon(ClipyIcons.delete_outline, size = 18.dp, color = colors.error); Spacer(Modifier.width(8.dp)); Text(relayText(zh, "解散设备组", "Disband group")) }
                        }
                    }
                }
                if (state.pending && !state.revoked) {
                    Spacer(Modifier.height(24.dp))
                    GroupSection(if (state.pendingAutomatic) relayText(zh, "正在自动加入", "Joining automatically") else relayText(zh, "等待批准", "Awaiting approval"),
                        if (state.pendingAutomatic) relayText(zh, "正在验证邀请并加入设备组，无需邀请设备批准。", "Verifying the invitation and joining without manager approval.")
                        else relayText(zh, "在邀请设备上核对下方配对码并批准，批准后将自动加入。", "Compare this code on the inviting device and approve. Joining will complete automatically.")) {
                        if (!state.pendingAutomatic) GroupCode(state.pendingCode)
                        Spacer(Modifier.height(24.dp))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(if (state.pendingAutomatic) relayText(zh, "正在自动加入…", "Joining automatically…") else relayText(zh, "批准后自动加入", "Joins automatically after approval"))
                            TextButton(onClick = { scope.launch { controller.discardRequest() } }, enabled = !state.busy) { Text(relayText(zh, "放弃本次申请", "Discard request")) }
                        }
                    }
                }
                if (state.request != null && !state.revoked) {
                    Spacer(Modifier.height(24.dp))
                    GroupSection(relayText(zh, "确认新设备", "Confirm new device"), state.request!!.name) {
                        Text(relayText(zh, "核对新设备上的配对码", "Compare the code on the new device")); Spacer(Modifier.height(12.dp)); GroupCode(state.request!!.code)
                        Spacer(Modifier.height(20.dp))
                        GroupSwitch(grantManager, { grantManager = it }, !state.busy, relayText(zh, "允许管理设备组", "Allow group management"), relayText(zh, "可以邀请和移除其他设备。", "Can invite and remove other devices."))
                        Spacer(Modifier.height(20.dp))
                        RelayFilledButton(relayText(zh, "配对码一致，批准加入", "Codes match — approve"), !state.busy, modifier = Modifier.fillMaxWidth()) { scope.launch { controller.approve(grantManager) } }
                    }
                }
                if (state.invitationLink.isNotEmpty() && !state.revoked) {
                    Spacer(Modifier.height(24.dp))
                    GroupSection(relayText(zh, "邀请新设备", "Invite a device"), relayText(zh, "用新设备扫描二维码。邀请有效期为 10 分钟。", "Scan with the new device. Invitations expire after 10 minutes.")) {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { RelayQr(state.invitationLink, zh) }
                        Spacer(Modifier.height(24.dp))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(if (state.invitationAutomatic) relayText(zh, "扫码后自动加入（普通成员）", "Joins automatically as a member") else relayText(zh, "加入申请会自动显示", "Join requests appear automatically"))
                            GroupOutlineButton(relayText(zh, "复制邀请链接", "Copy invitation link"), !state.busy) { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Clipy", state.invitationLink)) }
                            TextButton(onClick = { scope.launch { controller.cancelInvitation() } }, enabled = !state.busy) { Text(relayText(zh, "取消邀请", "Cancel invitation")) }
                        }
                    }
                }
            }
        }
    }
    if (active) {
        rename?.let { member ->
            val saveName = {
                val value = renameValue.trim()
                if (value.isEmpty() || value.toByteArray().size > 128) renameInvalid = true
                else { rename = null; scope.launch { controller.renameMember(member.device, value) }; Unit }
            }
            AlertDialog(onDismissRequest = { rename = null }, containerColor = colors.surface, shape = RoundedCornerShape(24.dp),
                title = { Text(relayText(zh, "修改设备名称", "Rename device")) }, text = {
                    RelayField(renameValue, { renameValue = it; renameInvalid = false }, relayText(zh, "设备名称", "Device name"),
                        error = if (renameInvalid) relayText(zh, "请输入简短的设备名称", "Enter a short device name") else null,
                        autofocus = true, submit = saveName)
                },
                dismissButton = { TextButton(onClick = { rename = null }) { Text(relayText(zh, "取消", "Cancel")) } },
                confirmButton = { RelayFilledButton(relayText(zh, "保存名称", "Save name"), click = saveName) })
        }
        confirmation?.let { confirm ->
            val remove = confirm as? GroupConfirmation.Remove
            val disband = (confirm as? GroupConfirmation.Exit)?.disband == true
            val title = if (remove != null) relayText(zh, "移除设备？", "Remove device?") else if (state.revoked) relayText(zh, "清除失效的组配置？", "Clear unavailable group configuration?") else if (disband) relayText(zh, "解散整个设备组？", "Disband this group?") else relayText(zh, "退出当前设备组？", "Leave this group?")
            val text = if (remove != null) relayText(zh, "移除 ${remove.member.name} 后，它将无法访问本组的公网中继。局域网连接与已收到的内容不受影响。", "${remove.member.name} will lose access to this relay group. LAN connections and previously received content are unaffected.")
                else if (state.revoked) relayText(zh, "只清除本机已失效的公网组配置，保留历史记录和局域网设置。然后可创建或加入其他设备组。", "Clear only this device’s unavailable relay configuration. Local history and LAN settings are preserved. You can then create or join another group.")
                else if (disband) relayText(zh, "所有设备将失去本组的公网访问权限，未使用的邀请也会失效。此操作不可撤销；本机历史记录和局域网配置会保留。", "All devices will lose access to this relay group and invitations will expire. This cannot be undone. Local history and LAN settings are preserved.")
                else relayText(zh, "仅本机离开；其他设备继续使用。若组内只剩本机，空组会同时关闭。本机历史记录和局域网配置会保留。", "Only this device leaves; other devices continue using the group. A group with no remaining devices closes. Local history and LAN settings are preserved.")
            AlertDialog(onDismissRequest = { confirmation = null }, containerColor = colors.surface, shape = RoundedCornerShape(24.dp), title = { Text(title) }, text = { Text(text) },
                dismissButton = { TextButton(onClick = { confirmation = null }) { Text(relayText(zh, "取消", "Cancel")) } },
                confirmButton = { RelayFilledButton(if (remove != null) relayText(zh, "移除", "Remove") else if (state.revoked) relayText(zh, "清除并继续", "Clear and continue") else if (disband) relayText(zh, "确认解散", "Disband group") else relayText(zh, "确认退出", "Leave group"), destructive = remove == null) {
                    confirmation = null; scope.launch { if (remove != null) controller.removeMember(remove.member.device) else controller.exitGroup(disband) }
                } })
        }
    }
}

@Composable private fun GroupSection(title: String, subtitle: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.padding(20.dp)) {
            ClipyHeadingText(title, style = MaterialTheme.typography.titleLarge)
            if (subtitle.isNotEmpty()) { Spacer(Modifier.height(8.dp)); Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Spacer(Modifier.height(24.dp)); content()
        }
    }
}
@Composable private fun GroupOutlineButton(text: String, enabled: Boolean, icon: Int? = null, modifier: Modifier = Modifier, click: () -> Unit) {
    OutlinedButton(click, enabled = enabled, modifier = modifier.heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp), contentPadding = clipyButtonPadding(icon != null)) {
        if (icon != null) { ClipyButtonIcon(icon); Spacer(Modifier.width(clipyButtonSpacing())) }
        Text(text)
    }
}
@Composable private fun GroupCode(value: String) { SelectionContainer { Text(value, style = MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Monospace, letterSpacing = 3.sp)) } }
@Composable private fun GroupSwitch(value: Boolean, change: (Boolean) -> Unit, enabled: Boolean, title: String, subtitle: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 72.dp).toggleable(value = value, enabled = enabled, role = Role.Switch, onValueChange = change), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title, style = MaterialTheme.typography.bodyLarge); Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Switch(value, null, enabled = enabled)
    }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun GroupMember(member: RelayMember, state: RelayUiState, zh: Boolean, rename: () -> Unit, remove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val tooltip = rememberTooltipState()
    val active = LocalPageActive.current
    LaunchedEffect(active) { if (!active) tooltip.dismiss() }
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(member.name + if (member.device == state.self) relayText(zh, "（本机）", " (this device)") else "", style = MaterialTheme.typography.bodyLarge)
            Spacer(Modifier.height(8.dp))
            Text("${if (member.manager) relayText(zh, "管理员", "Manager") else relayText(zh, "成员", "Member")} · ${if (!state.onlineKnown) relayText(zh, "状态未刷新", "Status not refreshed") else if (member.online) relayText(zh, "在线", "Online") else relayText(zh, "离线", "Offline")}", style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(6.dp))
            TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
                tooltip = { PlainTooltip { Text(member.device) } }, state = tooltip, enableUserInput = active) {
                Text(member.device, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (state.canManage || member.device == state.self) Box {
            IconButton(onClick = { menu = true }, enabled = !state.busy) { ClipyIcon(ClipyIcons.more_vert, description = relayText(zh, "设备操作", "Device actions")) }
            DropdownMenu(menu && LocalPageActive.current, { menu = false }) {
                DropdownMenuItem(text = { Text(relayText(zh, "修改设备名称", "Rename device")) }, onClick = { menu = false; rename() })
                if (state.canManage && member.device != state.self) DropdownMenuItem(text = { Text(relayText(zh, "移除设备", "Remove device")) }, onClick = { menu = false; remove() })
            }
        }
    }
}
@Composable private fun GroupLegacy(state: RelayUiState, zh: Boolean) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ClipyIcon(ClipyIcons.check_circle_outline); Spacer(Modifier.width(8.dp))
            Text(relayText(zh, "已接入设备组", "Already enrolled"), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
        }
        Spacer(Modifier.height(8.dp)); SelectionContainer { Text(state.groupId, style = MaterialTheme.typography.titleMedium) }
        SelectionContainer { Text("${relayText(zh, "本机设备 ID", "This device")}: ${state.self}") }
        HorizontalDivider(Modifier.padding(vertical = 16.dp))
        Text(relayText(zh, "组管理待启用", "Group management pending"), style = MaterialTheme.typography.titleMedium)
        Text(relayText(zh, "原有设备组和同步配置已保留。新版添加、移除设备功能需要服务端升级，并为当前组启用管理权限；无需重新加入设备组。", "Your existing group and sync configuration are preserved. Adding and removing devices requires the server update and management activation for this group. You do not need to join again."))
        if (state.trustedDevices.isNotEmpty()) {
            Spacer(Modifier.height(16.dp)); Text(relayText(zh, "本机已保存的可信设备", "Trusted devices saved on this device"), style = MaterialTheme.typography.titleSmall)
            state.trustedDevices.forEach { SelectionContainer { Text(it, Modifier.padding(vertical = 4.dp)) } }
            Text(relayText(zh, "这是本机保存的信任列表，并非服务器完整成员列表。", "This is the locally saved trust list, not the complete server membership list."))
        }
    }
}
@Composable private fun RelayQr(value: String, zh: Boolean) {
    var bitmap by remember(value) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(value) {
        bitmap = withContext(Dispatchers.Default) {
            val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 206, 206, mapOf(EncodeHintType.MARGIN to 0, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.L))
            android.graphics.Bitmap.createBitmap(matrix.width, matrix.height, android.graphics.Bitmap.Config.ARGB_8888).also { image ->
                val pixels = IntArray(matrix.width * matrix.height) { index -> if (matrix[index % matrix.width, index / matrix.width]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
                image.setPixels(pixels, 0, matrix.width, 0, 0, matrix.width, matrix.height)
            }
        }
    }
    Box(Modifier.background(Color.White, RoundedCornerShape(16.dp)).padding(12.dp)) {
        Box(Modifier.size(230.dp).padding(12.dp), contentAlignment = Alignment.Center) {
            bitmap?.let { Image(it.asImageBitmap(), relayText(zh, "邀请二维码", "Invitation QR code"), Modifier.fillMaxSize(), filterQuality = FilterQuality.None) }
        }
    }
}

private fun groupNotice(zh: Boolean, value: RelayNotice): String = when (value) {
    RelayNotice.INVALID_GROUP_NAME -> relayText(zh, "请填写简短的设备组名称和本机名称。", "Enter a short group name and device name.")
    RelayNotice.FAILED -> relayText(zh, "操作失败，请检查网络、邀请有效期或管理权限。", "Could not complete. Check connection, invitation expiry and permissions.")
    RelayNotice.REVOKED -> relayText(zh, "当前设备的组接入已失效，请返回创建或加入。", "This group access is no longer valid. Return to create or join a group.")
    RelayNotice.RATE_LIMITED -> relayText(zh, "创建暂时达到上限，请稍后重试。", "Group creation limit reached. Please retry later.")
    RelayNotice.JOINED -> relayText(zh, "已加入，公网中继已启用。", "Joined. Internet relay enabled.")
    RelayNotice.CREATED -> relayText(zh, "设备组已创建，你是管理员。现在可以添加其他设备。", "Group created. You are the manager and can now add devices.")
    RelayNotice.REQUESTED -> relayText(zh, "请在邀请设备上核对配对码并批准。", "Verify the pairing code and approve on the inviting device.")
    RelayNotice.WAITING -> relayText(zh, "正在等待邀请设备批准。", "Waiting for approval on the inviting device.")
    RelayNotice.AUTO_JOINING -> relayText(zh, "正在自动加入…", "Joining automatically…")
    RelayNotice.AUTO_JOINED -> relayText(zh, "新设备已自动加入。", "Device joined automatically.")
    RelayNotice.APPROVED -> relayText(zh, "已批准，新设备将自动加入。", "Approved. The new device will join automatically.")
    RelayNotice.NAME_UPDATED -> relayText(zh, "设备名称已更新。", "Device name updated.")
    RelayNotice.LEFT -> relayText(zh, "已退出当前组，可以创建或加入其他组。", "You left the group. Create or join another group.")
    RelayNotice.DISBANDED -> relayText(zh, "设备组已解散，可以创建或加入其他组。", "Group disbanded. Create or join another group.")
    RelayNotice.INVITATION_EXPIRED -> relayText(zh, "邀请已过期，请重新添加设备。", "Invitation expired. Add the device again.")
    RelayNotice.NO_REQUEST -> relayText(zh, "还没有设备申请加入。", "No device has requested to join yet.")
    RelayNotice.LAST_MANAGER -> relayText(zh, "你是最后一位管理员。请让另一台管理设备加入，或选择解散设备组。", "You are the last manager. Invite another manager or disband the group.")
}
