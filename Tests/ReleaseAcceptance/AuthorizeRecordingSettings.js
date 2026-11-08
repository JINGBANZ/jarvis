ObjC.import("Foundation");
ObjC.import("AppKit");

function run() {
    let stage = "input";
    const diagnostics = {
        uiElementsEnabled: false,
        processCount: 0,
        windowCount: 0,
        usernameCount: 0,
        secureCount: 0,
        modifySettingsCount: 0,
        recognizedHeading: false,
        recognizedText: false,
        frontmostProcessCount: 0,
        frontmostContainerCount: 0,
        frontmostUsernameCount: 0,
        frontmostSecureCount: 0,
        frontmostModifySettingsCount: 0,
        frontmostIsSystemSettings: false,
        frontmostIsLocalAuthentication: false,
        frontmostRecognizedHeading: false,
        frontmostRecognizedText: false
    };
    const receipt = authorized => JSON.stringify({authorized, stage, diagnostics});
    let lastProgress = null;
    function publish(authorized = false) {
        const value = receipt(authorized);
        if (value !== lastProgress) {
            $.NSFileHandle.fileHandleWithStandardOutput.writeData($(value + "\n").dataUsingEncoding($.NSUTF8StringEncoding));
            lastProgress = value;
        }
    }
    try {
        publish();
        const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
        const credentials = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding)));
        if (Object.keys(credentials).sort().join(",") !== "password,username"
            || credentials.username !== "jarvisacceptance"
            || typeof credentials.password !== "string"
            || !/^[A-Za-z0-9_-]{32,128}$/.test(credentials.password)) {
            return receipt(false);
        }
        const environment = $.NSProcessInfo.processInfo.environment;
        if (ObjC.unwrap(environment.objectForKey("GITHUB_ACTIONS")) !== "true"
            || ObjC.unwrap(environment.objectForKey("RUNNER_ENVIRONMENT")) !== "github-hosted"
            || ObjC.unwrap($.NSUserName()) !== "runner"
            || ObjC.unwrap($.NSHomeDirectory()) !== "/Users/runner") {
            return receipt(false);
        }
        stage = "accessibility";
        publish();
        const events = Application("System Events");
        diagnostics.uiElementsEnabled = events.uiElementsEnabled() === true;
        publish();
        if (!diagnostics.uiElementsEnabled) { return receipt(false); }

        function attribute(element, name) {
            const value = element.attributes.byName(name);
            return value.exists() ? value.value() : null;
        }

        function inspect(window) {
            const nodes = [];
            const pending = [window];
            while (pending.length > 0) {
                if (nodes.length >= 256) { throw new Error(); }
                const element = pending.shift();
                nodes.push({element, role: attribute(element, "AXRole"), subrole: attribute(element, "AXSubrole")});
                pending.push(...element.uiElements());
            }
            const text = nodes.filter(node => node.role === "AXStaticText").flatMap(node =>
                ["AXValue", "AXTitle", "AXDescription"].map(name => attribute(node.element, name))
                    .filter(value => typeof value === "string")
            ).join(" ").replace(/\s+/g, " ");
            const username = nodes.filter(node => node.role === "AXTextField" && node.subrole !== "AXSecureTextField");
            const secure = nodes.filter(node => node.role === "AXSecureTextField" || node.subrole === "AXSecureTextField");
            const modify = nodes.filter(node => node.role === "AXButton"
                && (attribute(node.element, "AXTitle") === "Modify Settings"
                    || attribute(node.element, "AXDescription") === "Modify Settings"));
            const summary = {
                recognizedHeading: text.includes("Privacy & Security"),
                recognizedText: text.toLowerCase().includes("modify your system settings"),
                usernameCount: username.length,
                secureCount: secure.length,
                modifySettingsCount: modify.length
            };
            const form = summary.recognizedHeading && summary.recognizedText
                && username.length === 1 && secure.length === 1 && modify.length === 1
                ? {window, username: username[0].element, secure: secure[0].element, modify: modify[0].element} : null;
            return {form, diagnostics: summary};
        }

        function inspectFrontmost() {
            const summary = {
                frontmostProcessCount: 0,
                frontmostContainerCount: 0,
                frontmostUsernameCount: 0,
                frontmostSecureCount: 0,
                frontmostModifySettingsCount: 0,
                frontmostIsSystemSettings: false,
                frontmostIsLocalAuthentication: false,
                frontmostRecognizedHeading: false,
                frontmostRecognizedText: false
            };
            try {
                const processes = events.processes.whose({frontmost: true})();
                summary.frontmostProcessCount = Math.min(processes.length, 256);
                if (processes.length !== 1) { return summary; }
                const identifier = processes[0].bundleIdentifier();
                summary.frontmostIsSystemSettings = identifier === "com.apple.systempreferences";
                summary.frontmostIsLocalAuthentication = identifier === "com.apple.LocalAuthenticationRemoteService";
                const containers = processes[0].uiElements();
                summary.frontmostContainerCount = Math.min(containers.length, 256);
                let bestScore = -1;
                for (const container of containers.slice(0, 256)) {
                    try {
                        const observed = inspect(container).diagnostics;
                        const score = 8 * (Number(observed.recognizedHeading) + Number(observed.recognizedText))
                            + Number(observed.usernameCount === 1) + Number(observed.secureCount === 1)
                            + Number(observed.modifySettingsCount === 1);
                        if (score > bestScore) {
                            bestScore = score;
                            Object.assign(summary, {
                                frontmostUsernameCount: observed.usernameCount,
                                frontmostSecureCount: observed.secureCount,
                                frontmostModifySettingsCount: observed.modifySettingsCount,
                                frontmostRecognizedHeading: observed.recognizedHeading,
                                frontmostRecognizedText: observed.recognizedText
                            });
                        }
                    } catch (_) {
                        // A disappearing or oversized foreground tree must not abort authorization.
                    }
                }
            } catch (_) {
                // Foreground discovery is read-only and independent of the validated form.
            }
            return summary;
        }

        const deadline = Date.now() + 180000;
        const owner = "com.apple.LocalAuthenticationRemoteService";
        let form = null;
        let hydrationDeadline = null;
        stage = "owner";
        publish();
        while (Date.now() < deadline && form === null) {
            const processes = events.processes.whose({bundleIdentifier: owner})();
            diagnostics.processCount = Math.min(processes.length, 256);
            if (processes.length === 0) {
                stage = "owner";
                Object.assign(diagnostics, {windowCount: 0, usernameCount: 0, secureCount: 0,
                    modifySettingsCount: 0, recognizedHeading: false, recognizedText: false});
            }
            publish();
            if (processes.length > 1) { return receipt(false); }
            if (processes.length === 1) {
                if (stage === "owner") { stage = "form"; publish(); }
                const windows = processes[0].windows();
                diagnostics.windowCount = Math.min(windows.length, 256);
                if (windows.length === 0) {
                    stage = "form";
                    Object.assign(diagnostics, {usernameCount: 0, secureCount: 0,
                        modifySettingsCount: 0, recognizedHeading: false, recognizedText: false});
                    Object.assign(diagnostics, inspectFrontmost());
                }
                publish();
                if (windows.length > 256) { return receipt(false); }
                if (windows.length > 0 && hydrationDeadline === null) { hydrationDeadline = Date.now() + 10000; }
                const inspected = windows.map(inspect);
                const matches = inspected.filter(value => value.form !== null);
                if (matches.length > 1) { return receipt(false); }
                const selected = matches[0]
                    || inspected.find(value => value.diagnostics.recognizedHeading || value.diagnostics.recognizedText)
                    || inspected[0];
                if (selected) {
                    Object.assign(diagnostics, selected.diagnostics);
                    if (diagnostics.recognizedHeading && diagnostics.recognizedText) { stage = "fields"; }
                }
                if (matches.length === 1) { form = matches[0].form; }
                publish();
            }
            if (form === null && hydrationDeadline !== null && Date.now() >= hydrationDeadline) { return receipt(false); }
            if (form === null) { $.NSThread.sleepForTimeInterval(0.25); }
        }
        if (form === null) { return receipt(false); }

        function fill(field, value) {
            stage = "fill";
            publish();
            const attribute = field.attributes.byName("AXValue");
            if (attribute.exists() && attribute.settable()) {
                attribute.value = value;
                return;
            }
            stage = "clipboard";
            publish();
            const clipboard = $.NSPasteboard.generalPasteboard;
            const saved = [];
            const items = clipboard.pasteboardItems;
            for (let index = 0; index < Number(items.count); index++) {
                const original = items.objectAtIndex(index);
                const copy = $.NSPasteboardItem.alloc.init;
                const types = original.types;
                for (let typeIndex = 0; typeIndex < Number(types.count); typeIndex++) {
                    const type = types.objectAtIndex(typeIndex);
                    copy.setDataForType(original.dataForType(type), type);
                }
                saved.push(copy);
            }
            clipboard.clearContents;
            try {
                if (!clipboard.setStringForType(value, $.NSPasteboardTypeString)) { throw new Error(); }
                events.click(field);
                const focused = field.attributes.byName("AXFocused");
                if (!focused.exists() || focused.value() !== true) { throw new Error(); }
                events.keystroke("a", {using: ["command down"]});
                events.keystroke("v", {using: ["command down"]});
            } finally {
                clipboard.clearContents;
                if (saved.length > 0 && !clipboard.writeObjects($(saved))) { throw new Error(); }
            }
        }

        fill(form.username, credentials.username);
        fill(form.secure, credentials.password);
        stage = "submit";
        publish();
        events.click(form.modify);
        stage = "dismiss";
        publish();
        const dismissalDeadline = Date.now() + 15000;
        while (Date.now() < dismissalDeadline) {
            if (!form.window.exists()) {
                stage = "complete";
                publish(true);
                return receipt(true);
            }
            $.NSThread.sleepForTimeInterval(0.25);
        }
        return receipt(false);
    } catch (_) {
        publish();
        return receipt(false);
    }
}
