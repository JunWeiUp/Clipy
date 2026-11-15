import { cleanup, mount, platform } from "nsh";
import { Application } from "nsh/desktop";
import process from "process";
import { createController } from "./src/app/controller";
import { installLibraryShortcuts } from "./src/app/library-shortcuts";
import { installDesktop } from "./src/app/desktop";
import { RootScreen } from "./src/screens/RootScreen";

function App() {
    const app = createController();
    if (platform.os === "macos") {
        const desktop = installDesktop(
            app.model,
            app.actions,
            !!process.env.CLIPY_NSH_HELPER,
        );
        app.setDesktopConfigure(desktop.configureSettings);
        const stopMenu = app.bridge.on("menubar.click", (event) =>
            desktop.panel(event.bounds),
        );
        cleanup(stopMenu);
        installLibraryShortcuts(app.model, app.actions);
    }
    const off = Application.on("quit", async () => {
        try {
            await app.actions.flushDrafts?.();
        } finally {
            await app.dispose();
        }
    });
    cleanup(() => {
        off();
        void app.dispose();
    });
    if (process.env.CLIPY_NSH_HELPER) void app.start();
    return (
        <If when={app.model.state().uiVisible !== false}>
            <RootScreen model={app.model} actions={app.actions} />
        </If>
    );
}
mount(App);
