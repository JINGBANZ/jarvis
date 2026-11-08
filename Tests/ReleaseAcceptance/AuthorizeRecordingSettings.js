ObjC.import("Foundation");
ObjC.import("AppKit");

function run() {
    let stage = "input";
    const diagnostics = {
        uiElementsEnabled: false,
        processCount: 0,
        windowCount: 0,
        ownerContainerCount: 0,
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
        frontmostRecognizedText: false,
        focusAvailable: false,
        focusContainerAvailable: false,
        focusIsSecureField: false,
        focusOwnerIsLocalAuthentication: false,
        focusOwnerIsSystemSettings: false,
        focusOwnerIsSecurityAgent: false,
        focusOwnerPID: 0,
        focusContainerPID: 0,
        focusContainerIsSheet: false,
        focusContainerIsWindow: false,
        focusError: 0
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
        ObjC.import("ApplicationServices");

        function attribute(element, name) {
            const value = element.attributes.byName(name);
            return value.exists() ? value.value() : null;
        }

        function inspect(window, discoveryBudget = null) {
            const nodes = [];
            const pending = [window];
            const withinDeadline = () => discoveryBudget === null || Date.now() < discoveryBudget.deadline;
            while (pending.length > 0) {
                if (!withinDeadline() || (discoveryBudget !== null && discoveryBudget.remaining === 0)) { break; }
                if (nodes.length >= 256) { throw new Error(); }
                if (discoveryBudget !== null) { discoveryBudget.remaining -= 1; }
                const element = pending.shift();
                nodes.push({element, role: attribute(element, "AXRole"), subrole: attribute(element, "AXSubrole")});
                if (withinDeadline()) { pending.push(...element.uiElements()); }
            }
            const textValues = [];
            for (const node of nodes.filter(node => node.role === "AXStaticText")) {
                for (const name of ["AXValue", "AXTitle", "AXDescription"]) {
                    if (!withinDeadline()) { break; }
                    const value = attribute(node.element, name);
                    if (typeof value === "string") { textValues.push(value); }
                }
            }
            const text = textValues.join(" ").replace(/\s+/g, " ");
            const username = nodes.filter(node => node.role === "AXTextField" && node.subrole !== "AXSecureTextField");
            const secure = nodes.filter(node => node.role === "AXSecureTextField" || node.subrole === "AXSecureTextField");
            const modify = nodes.filter(node => node.role === "AXButton" && withinDeadline()
                && (attribute(node.element, "AXTitle") === "Modify Settings"
                    || attribute(node.element, "AXDescription") === "Modify Settings"));
            const summary = {
                recognizedHeading: text.includes("Privacy & Security"),
                recognizedText: text.toLowerCase().includes("modify your system settings"),
                usernameCount: username.length,
                secureCount: secure.length,
                modifySettingsCount: modify.length
            };
            const form = discoveryBudget === null && summary.recognizedHeading && summary.recognizedText
                && username.length === 1 && secure.length === 1 && modify.length === 1
                ? {window, username: username[0].element, secure: secure[0].element, modify: modify[0].element} : null;
            return {form, diagnostics: summary};
        }

        function inspectContainers(containers, budget) {
            let summary = {usernameCount: 0, secureCount: 0, modifySettingsCount: 0,
                recognizedHeading: false, recognizedText: false};
            let bestScore = -1;
            for (const container of containers.slice(0, 256)) {
                if (budget.remaining === 0 || Date.now() >= budget.deadline) { break; }
                try {
                    const observed = inspect(container, budget).diagnostics;
                    const score = 8 * (Number(observed.recognizedHeading) + Number(observed.recognizedText))
                        + Number(observed.usernameCount === 1) + Number(observed.secureCount === 1)
                        + Number(observed.modifySettingsCount === 1);
                    if (score > bestScore) {
                        bestScore = score;
                        summary = observed;
                    }
                } catch (_) {
                    // A disappearing discovery tree must not abort authorization.
                }
            }
            return summary;
        }

        function inspectOwnerRoots(process, budget) {
            const summary = {ownerContainerCount: 0, usernameCount: 0, secureCount: 0,
                modifySettingsCount: 0, recognizedHeading: false, recognizedText: false};
            try {
                const containers = process.uiElements();
                summary.ownerContainerCount = Math.min(containers.length, 256);
                if (summary.ownerContainerCount !== diagnostics.ownerContainerCount) {
                    diagnostics.ownerContainerCount = summary.ownerContainerCount;
                    publish();
                }
                Object.assign(summary, inspectContainers(containers, budget));
            } catch (_) {
                // Windowless discovery cannot authorize credential entry.
            }
            return summary;
        }

        function inspectFrontmost(budget) {
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
                const basicFields = ["frontmostProcessCount", "frontmostContainerCount",
                    "frontmostIsSystemSettings", "frontmostIsLocalAuthentication"];
                if (basicFields.some(key => summary[key] !== diagnostics[key])) {
                    Object.assign(diagnostics, summary);
                    publish();
                }
                const observed = inspectContainers(containers, budget);
                Object.assign(summary, {
                    frontmostUsernameCount: observed.usernameCount,
                    frontmostSecureCount: observed.secureCount,
                    frontmostModifySettingsCount: observed.modifySettingsCount,
                    frontmostRecognizedHeading: observed.recognizedHeading,
                    frontmostRecognizedText: observed.recognizedText
                });
            } catch (_) {
                // Foreground discovery is read-only and independent of the validated form.
            }
            return summary;
        }

        function inspectFocus(budget) {
            const summary = {
                focusAvailable: false, focusContainerAvailable: false, focusIsSecureField: false,
                focusOwnerIsLocalAuthentication: false, focusOwnerIsSystemSettings: false,
                focusOwnerIsSecurityAgent: false, focusOwnerPID: 0, focusContainerPID: 0,
                focusContainerIsSheet: false, focusContainerIsWindow: false, focusError: 0
            };
            function recordError(code) {
                if (summary.focusError === 0 && code !== 0) {
                    summary.focusError = Number.isInteger(code) && code >= -25214 && code <= -25200 ? code : -25200;
                }
            }
            function withinDeadline() {
                if (Date.now() < budget.deadline) { return true; }
                recordError(-25204);
                return false;
            }
            function read(element, name) {
                if (!withinDeadline()) { return null; }
                const value = Ref();
                const error = Number($.AXUIElementCopyAttributeValue(element, $(name), value));
                recordError(error);
                return error === 0 ? value[0] : null;
            }
            function pid(element) {
                if (!withinDeadline()) { return 0; }
                const value = Ref();
                const error = Number($.AXUIElementGetPid(element, value));
                recordError(error);
                if (error !== 0) { return 0; }
                const identifier = Number(value[0]);
                if (Number.isInteger(identifier) && identifier > 0 && identifier <= 2147483647) { return identifier; }
                recordError(-25200);
                return 0;
            }
            function roleValue(element, name) {
                const value = read(element, name);
                return value ? ObjC.unwrap(value) : null;
            }
            try {
                publish();
                if (!withinDeadline()) { return summary; }
                const system = $.AXUIElementCreateSystemWide();
                const timeoutError = Number($.AXUIElementSetMessagingTimeout(system, 0.25));
                recordError(timeoutError);
                if (timeoutError !== 0) { return summary; }
                const focused = read(system, "AXFocusedUIElement");
                if (!focused) { return summary; }
                summary.focusAvailable = true;
                summary.focusOwnerPID = pid(focused);
                if (summary.focusOwnerPID > 0) {
                    const application = $.NSRunningApplication.runningApplicationWithProcessIdentifier(summary.focusOwnerPID);
                    const identifier = ObjC.unwrap(application.bundleIdentifier);
                    summary.focusOwnerIsLocalAuthentication = identifier === "com.apple.LocalAuthenticationRemoteService";
                    summary.focusOwnerIsSystemSettings = identifier === "com.apple.systempreferences";
                    summary.focusOwnerIsSecurityAgent = identifier === "com.apple.SecurityAgent";
                }
                const role = roleValue(focused, "AXRole");
                const subrole = roleValue(focused, "AXSubrole");
                summary.focusIsSecureField = role === "AXSecureTextField" || subrole === "AXSecureTextField";
                const container = read(focused, "AXTopLevelUIElement") || read(focused, "AXWindow");
                if (container) {
                    summary.focusContainerAvailable = true;
                    summary.focusContainerPID = pid(container);
                    const containerRole = roleValue(container, "AXRole");
                    summary.focusContainerIsSheet = containerRole === "AXSheet";
                    summary.focusContainerIsWindow = containerRole === "AXWindow";
                }
            } catch (_) {
                recordError(-25200);
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
                Object.assign(diagnostics, {windowCount: 0, ownerContainerCount: 0, usernameCount: 0, secureCount: 0,
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
                    const budget = {remaining: 128, deadline: Date.now() + 3000};
                    Object.assign(diagnostics, inspectFocus(budget));
                    publish();
                    Object.assign(diagnostics, inspectOwnerRoots(processes[0], budget));
                    Object.assign(diagnostics, inspectFrontmost(budget));
                } else {
                    diagnostics.ownerContainerCount = 0;
                }
                publish();
                if (windows.length > 256) { return receipt(false); }
                if (windows.length > 0 && hydrationDeadline === null) { hydrationDeadline = Date.now() + 10000; }
                const inspected = windows.map(window => inspect(window));
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
