ObjC.import("Foundation");
ObjC.import("AppKit");

function run() {
    let stage = "input";
    const diagnostics = {
        processCount: 0, formCount: 0, usernameCount: 0, secureCount: 0, modifySettingsCount: 0,
        uiElementsEnabled: false, recognizedHeading: false, recognizedText: false,
        focusAvailable: false, focusIsSecureField: false, focusOwnerIsAuthenticationAgent: false,
        focusOwnerIsSystemSettings: false, focusOwnerIsSecurityPrivacyExtension: false,
        focusOwnerPID: 0, focusError: 0, usernameOwnerPID: 0,
        usernameOwnerIsAuthenticationAgent: false, usernameOwnerIsSystemSettings: false,
        usernameOwnerIsSecurityPrivacyExtension: false
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
    function fail(code = -25200) {
        diagnostics.focusError = Number.isInteger(code) && code >= -25214 && code <= -25200 ? code : -25200;
        const error = new Error();
        error.axError = diagnostics.focusError;
        throw error;
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
        ObjC.import("Security");
        // Automatic metadata exposes copied CF attributes as opaque pointers; AX references are toll-free objects.
        ObjC.bindFunction("AXUIElementCreateSystemWide", ["id", []]);
        ObjC.bindFunction("AXUIElementCopyAttributeValue", ["int", ["id", "id", "id *"]]);
        ObjC.bindFunction("AXUIElementGetPid", ["int", ["id", "int *"]]);
        ObjC.bindFunction("AXUIElementSetMessagingTimeout", ["int", ["id", "float"]]);
        ObjC.bindFunction("AXUIElementIsAttributeSettable", ["int", ["id", "id", "bool *"]]);
        ObjC.bindFunction("AXUIElementSetAttributeValue", ["int", ["id", "id", "id"]]);
        ObjC.bindFunction("AXUIElementPerformAction", ["int", ["id", "id"]]);
        ObjC.bindFunction("CFEqual", ["bool", ["id", "id"]]);
        ObjC.bindFunction("CFDictionarySetValue", ["void", ["id", "pointer", "id"]]);
        ObjC.bindFunction("SecCodeCopyGuestWithAttributes", ["int", ["id", "id", "unsigned int", "id *"]]);
        ObjC.bindFunction("SecRequirementCreateWithString", ["int", ["id", "unsigned int", "id *"]]);
        ObjC.bindFunction("SecCodeCheckValidity", ["int", ["id", "unsigned int", "id"]]);
        const system = $.AXUIElementCreateSystemWide();
        function check(error) { if (Number(error) !== 0) { fail(Number(error)); } }
        check($.AXUIElementSetMessagingTimeout(system, 0.25));
        const nativeRequirements = ["com.apple.settings.PrivacySecurity.extension",
            "com.apple.LocalAuthentication.UIAgent", "com.apple.systempreferences"].map(name => {
            const value = Ref();
            check($.SecRequirementCreateWithString($('anchor apple and identifier "' + name + '"'), 0, value));
            if (!value[0] || value[0].isNil()) { fail(); }
            return {name, requirement: value[0]};
        });

        function attribute(element, name, optional = false) {
            const value = Ref();
            const error = Number($.AXUIElementCopyAttributeValue(element, $(name), value));
            if (optional && (error === -25205 || error === -25212)) { return null; }
            check(error);
            return value[0] && !value[0].isNil() ? value[0] : null;
        }
        function scalar(element, name, optional = false) {
            const value = attribute(element, name, optional);
            return value ? ObjC.unwrap(value) : null;
        }
        function pid(element) {
            const value = Ref();
            check($.AXUIElementGetPid(element, value));
            const identifier = Number(value[0]);
            if (!Number.isInteger(identifier) || identifier <= 0 || identifier > 2147483647) { fail(); }
            return identifier;
        }
        function owner(identifier) {
            const attributes = $.NSMutableDictionary.dictionary;
            $.CFDictionarySetValue(attributes, $.kSecGuestAttributePid, $(identifier));
            const code = Ref();
            if (Number($.SecCodeCopyGuestWithAttributes($(), attributes, 0, code)) !== 0
                || !code[0] || code[0].isNil()) { return null; }
            for (const candidate of nativeRequirements) {
                if (Number($.SecCodeCheckValidity(code[0], 0, candidate.requirement)) === 0) { return candidate.name; }
            }
            return null;
        }
        function isNativeOwner(identifier) {
            return owner(identifier) !== null;
        }
        function isSecure(element) {
            return scalar(element, "AXRole") === "AXSecureTextField"
                || scalar(element, "AXSubrole", true) === "AXSecureTextField";
        }
        function same(first, second) { return first !== null && second !== null && Boolean($.CFEqual(first, second)); }
        function budget() { return {remaining: 128, deadline: Date.now() + 3000}; }

        function inspect(root, focused, limits) {
            const pending = [root];
            const text = [];
            const usernames = [];
            const secrets = [];
            const buttons = [];
            let complete = true;
            while (pending.length > 0) {
                if (limits.remaining === 0 || Date.now() >= limits.deadline) { complete = false; break; }
                limits.remaining -= 1;
                const element = pending.shift();
                const role = scalar(element, "AXRole");
                const subrole = scalar(element, "AXSubrole", true);
                if (role === "AXStaticText" || same(element, root)) {
                    for (const name of role === "AXStaticText" ? ["AXValue", "AXTitle", "AXDescription"] : ["AXTitle", "AXDescription"]) {
                        const value = scalar(element, name, true);
                        if (typeof value === "string") { text.push(value); }
                    }
                }
                if (role === "AXSecureTextField" || subrole === "AXSecureTextField") { secrets.push(element); }
                else if (role === "AXTextField") { usernames.push(element); }
                if (role === "AXButton" && (scalar(element, "AXTitle", true) === "Modify Settings"
                    || scalar(element, "AXDescription", true) === "Modify Settings")) { buttons.push(element); }
                const children = attribute(element, "AXChildren", true);
                if (children) {
                    const count = Number(children.count);
                    if (!Number.isInteger(count) || count < 0 || count > 256) { complete = false; break; }
                    for (let index = 0; index < count; index++) { pending.push(children.objectAtIndex(index)); }
                }
            }
            const content = text.join(" ").replace(/\s+/g, " ");
            const summary = {
                usernameCount: usernames.length, secureCount: secrets.length, modifySettingsCount: buttons.length,
                recognizedHeading: content.includes("Privacy & Security"),
                recognizedText: content.toLowerCase().includes("modify your system settings")
            };
            const matches = complete && summary.recognizedHeading && summary.recognizedText
                && usernames.length === 1 && secrets.length === 1 && buttons.length === 1
                && same(secrets[0], focused) && scalar(buttons[0], "AXEnabled") === true;
            return {summary, complete, secrets, form: matches
                ? {root, username: usernames[0], secure: secrets[0], modify: buttons[0]} : null};
        }

        let form = null;
        let hydrationDeadline = null;
        const deadline = Date.now() + 180000;
        stage = "owner";
        publish();
        while (Date.now() < deadline && form === null) {
            try {
                diagnostics.focusError = 0;
                const focused = attribute(system, "AXFocusedUIElement", true);
                const identifier = focused ? pid(focused) : 0;
                const name = identifier > 0 ? owner(identifier) : null;
                const secure = focused !== null && isSecure(focused);
                const native = name !== null;
                Object.assign(diagnostics, {
                    focusAvailable: focused !== null, focusIsSecureField: secure, focusOwnerPID: identifier,
                    focusOwnerIsAuthenticationAgent: name === "com.apple.LocalAuthentication.UIAgent",
                    focusOwnerIsSecurityPrivacyExtension: name === "com.apple.settings.PrivacySecurity.extension",
                    focusOwnerIsSystemSettings: name === "com.apple.systempreferences", processCount: native ? 1 : 0
                });
                publish();
                if (native && secure) {
                    stage = "form";
                    if (hydrationDeadline === null) { hydrationDeadline = Date.now() + 10000; }
                    const limits = budget();
                    let ancestor = attribute(focused, "AXParent", true);
                    for (let depth = 0; ancestor !== null && depth < 8; depth++) {
                        if (limits.remaining === 0 || Date.now() >= limits.deadline
                            || scalar(ancestor, "AXRole") === "AXApplication") { break; }
                        const inspected = inspect(ancestor, focused, limits);
                        Object.assign(diagnostics, inspected.summary);
                        if (inspected.form) {
                            form = {...inspected.form, pid: identifier};
                            diagnostics.formCount = 1;
                            break;
                        }
                        if (!inspected.complete) { break; }
                        ancestor = attribute(ancestor, "AXParent", true);
                    }
                    publish();
                }
            } catch (error) {
                if (![-25202, -25204, -25212].includes(error.axError)) { throw error; }
                stage = "owner";
                Object.assign(diagnostics, {
                    processCount: 0, formCount: 0, usernameCount: 0, secureCount: 0, modifySettingsCount: 0,
                    recognizedHeading: false, recognizedText: false, focusAvailable: false, focusIsSecureField: false,
                    focusOwnerIsAuthenticationAgent: false, focusOwnerIsSystemSettings: false,
                    focusOwnerIsSecurityPrivacyExtension: false, focusOwnerPID: 0
                });
                publish();
            }
            if (form === null && hydrationDeadline !== null && Date.now() >= hydrationDeadline) { return receipt(false); }
            if (form === null) { $.NSThread.sleepForTimeInterval(0.25); }
        }
        if (form === null) { return receipt(false); }
        stage = "fields";
        publish();

        function revalidate() {
            stage = "revalidate-owner";
            publish();
            if (!isNativeOwner(form.pid) || pid(form.secure) !== form.pid) { fail(); }
            stage = "revalidate-form";
            publish();
            const current = inspect(form.root, form.secure, budget()).form;
            stage = "revalidate-controls";
            publish();
            if (!current || !same(current.username, form.username) || !same(current.modify, form.modify)) { fail(); }
        }
        function settable(element, name) {
            const value = Ref();
            check($.AXUIElementIsAttributeSettable(element, $(name), value));
            return Boolean(value[0]);
        }
        function requireFocus(field) {
            stage = "focus-verify";
            publish();
            if (scalar(field, "AXFocused") !== true || !same(attribute(system, "AXFocusedUIElement"), field)) { fail(); }
        }
        function fill(field, value, secure) {
            revalidate();
            stage = "field-owner-query";
            publish();
            const identifier = pid(field);
            const name = secure ? null : owner(identifier);
            if (!secure) {
                Object.assign(diagnostics, {
                    usernameOwnerPID: identifier,
                    usernameOwnerIsAuthenticationAgent: name === "com.apple.LocalAuthentication.UIAgent",
                    usernameOwnerIsSystemSettings: name === "com.apple.systempreferences",
                    usernameOwnerIsSecurityPrivacyExtension: name === "com.apple.settings.PrivacySecurity.extension"
                });
            }
            stage = "field-owner";
            publish();
            if (secure ? identifier !== form.pid : name === null) { fail(); }
            stage = "focus-read";
            publish();
            if (!same(attribute(system, "AXFocusedUIElement"), field)) {
                stage = "focus-settable";
                publish();
                if (settable(field, "AXFocused")) {
                    stage = "focus-set";
                    publish();
                    check($.AXUIElementSetAttributeValue(field, $("AXFocused"), $(true)));
                } else {
                    stage = "focus-press";
                    publish();
                    check($.AXUIElementPerformAction(field, $("AXPress")));
                }
            }
            requireFocus(field);
            stage = "fill";
            publish();
            if (settable(field, "AXValue")) { check($.AXUIElementSetAttributeValue(field, $("AXValue"), $(value))); }
            else {
                requireFocus(field);
                events.keystroke("a", {using: ["command down"]});
                requireFocus(field);
                events.keystroke(value);
            }
            const readbackDeadline = Date.now() + 5000;
            while (Date.now() < readbackDeadline) {
                const observed = scalar(field, secure ? "AXNumberOfCharacters" : "AXValue", secure);
                if (secure ? observed === null || Number(observed) === value.length : observed === value) { return; }
                $.NSThread.sleepForTimeInterval(0.05);
            }
            fail();
        }
        fill(form.username, credentials.username, false);
        fill(form.secure, credentials.password, true);
        revalidate();
        requireFocus(form.secure);
        stage = "submit";
        publish();
        check($.AXUIElementPerformAction(form.modify, $("AXPress")));
        stage = "dismiss";
        publish();
        const dismissalDeadline = Date.now() + 15000;
        while (Date.now() < dismissalDeadline) {
            const value = Ref();
            const error = Number($.AXUIElementCopyAttributeValue(form.secure, $("AXParent"), value));
            if (error === -25202 || error === -25212) {
                stage = "complete";
                publish(true);
                return receipt(true);
            }
            check(error);
            let inspected;
            try {
                inspected = inspect(form.root, form.secure, budget());
            } catch (error) {
                if (error.axError !== -25202) { throw error; }
                const rootRole = Ref();
                const rootError = Number($.AXUIElementCopyAttributeValue(form.root, $("AXRole"), rootRole));
                if (rootError !== -25202) { throw error; }
                stage = "complete";
                diagnostics.focusError = 0;
                publish(true);
                return receipt(true);
            }
            if (inspected.complete && !inspected.secrets.some(element => same(element, form.secure))) {
                stage = "complete";
                publish(true);
                return receipt(true);
            }
            $.NSThread.sleepForTimeInterval(0.1);
        }
        return receipt(false);
    } catch (_) {
        publish();
        return receipt(false);
    }
}
