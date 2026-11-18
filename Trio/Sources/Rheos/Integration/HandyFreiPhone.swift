import CoreBluetooth
import CoreData
import Foundation
import LibreLoop
import MedtrumKit
import Security
import WatchConnectivity

/// Prepares Handy-frei. It never asks a driver to disconnect and never deletes a key.
enum HandyFreiPhone {
    private static let statusKey = "handyfrei.status"
    private static let logKey = "handyfrei.log"
    private static let reportKey = "handyfrei.report"
    private static let lock = NSLock()
    private static var pending: HandyFrei.Session?
    private static var lastSnapshot: HandyFrei.Snapshot?
    private static var logImported = false

    static var status: String {
        UserDefaults.standard.string(forKey: statusKey) ?? "Handy-frei ist aus."
    }

    static var lastReport: String {
        UserDefaults.standard.string(forKey: reportKey) ?? ""
    }

    static func prepare(fingerprint: HandyFrei.Fingerprint, snapshot: HandyFrei.Snapshot) -> HandyFrei.Session {
        HandyFrei.setEnabled(HandyFrei.isEnabled())
        if let refusal = snapshot.refusal {
            var session = HandyFrei.idle(fingerprint: fingerprint)
            session.enabled = HandyFrei.isEnabled()
            session.step = .failed(refusal)
            session.note = refusal
            session.phoneOwnsRadio = true
            session.watchOwnsRadio = false
            session.phoneLoopPaused = false
            session.keysDeleted = false
            lock.lock()
            pending = session
            logImported = false
            lastSnapshot = nil
            lock.unlock()
            HandyFreiGate.setPhoneLoopPaused(false)
            store(session)
            return session
        }
        let session = HandyFrei.prepare(enabled: HandyFrei.isEnabled(), fingerprint: fingerprint)
        lock.lock()
        pending = session
        logImported = false
        lastSnapshot = snapshot
        lock.unlock()
        if session.step != .offered {
            HandyFreiGate.setPhoneLoopPaused(false)
        }
        store(session)
        HandyFreiBluetoothWatch.shared.start()
        if session.step == .offered {
            send(session, snapshot: snapshot, kind: "prepare")
        }
        return session
    }

    /// Watch button, phone reachable. Fresh snapshot, loop paused, pairing kept.
    /// Drivers are not asked to unpair, prime, or deactivate.
    static func activateFromWatch(pump: Any?, cgm: Any?, storage: FileStorage?) {
        let document = RheosStore.shared.loadDocument()
        let learned = document.decision?.learnedFactors ?? document.applied?.factors
        let files = loopFiles(storage: storage)
        let snapshot = collectSnapshot(
            pump: pump,
            cgm: cgm,
            iob: 0,
            cob: 0,
            maxBolus: 0,
            maxIOB: 0,
            rheosBasal: learned?.basal ?? [],
            rheosISF: learned?.isf ?? [],
            rheosCarbRatio: learned?.carbRatio ?? [],
            loopFiles: files,
            glucose: nil
        )
        if snapshot.refusal != nil {
            _ = prepare(fingerprint: HandyFrei.Fingerprint(
                pumpPeripheralID: nil, pumpSerial: nil, sensorSerial: nil, sensorPeripheralID: nil
            ), snapshot: snapshot)
            return
        }
        let offered = HandyFrei.prepare(enabled: true, fingerprint: HandyFrei.Fingerprint(
            pumpPeripheralID: nil, pumpSerial: nil, sensorSerial: nil, sensorPeripheralID: nil
        ))
        let session = HandyFrei.watchTakesRadio(offered)
        HandyFreiGate.setPhoneLoopPaused(true)
        // Libre 3 allows one central. Drop the phone's link without deleting the sensor or its keys.
        releaseLibreRadio(cgm)
        lock.lock()
        pending = session
        logImported = false
        lastSnapshot = snapshot
        lock.unlock()
        store(session)
        send(session, snapshot: snapshot, kind: "watch-owns")
    }

    /// Called when iPhone Bluetooth reports poweredOff, or when the watch asks and it really is off.
    static func bluetoothIsOff() {
        lock.lock()
        let current = pending
        let snapshot = lastSnapshot
        lock.unlock()
        guard let current else { return }
        let session = HandyFrei.bluetoothIsOff(current)
        guard session.phoneLoopPaused else {
            store(session)
            return
        }
        HandyFreiGate.setPhoneLoopPaused(true)
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
        send(session, snapshot: snapshot, kind: "watch-owns")
    }

    static func watchSaysPhoneIsOff() {
        guard HandyFreiBluetoothWatch.shared.isPoweredOff else {
            lock.lock()
            var note = pending
            lock.unlock()
            note?.note = "Bluetooth am iPhone ist noch an. Bitte in den Einstellungen ausschalten."
            if let note {
                store(note)
                send(note, snapshot: nil, kind: "prepare")
            }
            return
        }
        bluetoothIsOff()
    }

    /// Stores the watch log, then lets the loop run again. Order is fixed: log first.
    static func importLog(_ entries: [[String: Any]]) {
        let data = try? JSONSerialization.data(withJSONObject: entries)
        if let data {
            UserDefaults.standard.set(data, forKey: logKey)
        }
        if let text = entries.reversed().compactMap({ $0["text"] as? String }).first(where: { !$0.isEmpty }) {
            UserDefaults.standard.set(text, forKey: reportKey)
        }
        storeDeliveries(entries)
        storeCarbs(entries)
        storeGlucose(entries)
        storeLoopStates(entries)
        storeAdjustments(entries)
        lock.lock()
        logImported = true
        let current = pending ?? HandyFrei.idle(fingerprint: HandyFrei.Fingerprint(
            pumpPeripheralID: nil, pumpSerial: nil, sensorSerial: nil, sensorPeripheralID: nil
        ))
        lock.unlock()
        let session = HandyFrei.resumeAfterLog(current, logImported: true)
        HandyFreiGate.setPhoneLoopPaused(false)
        resumeLibreRadio()
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
    }

    static func stop(fingerprint: HandyFrei.Fingerprint) -> HandyFrei.Session {
        let (session, _) = HandyFrei.stop(HandyFrei.idle(fingerprint: fingerprint))
        HandyFreiGate.setPhoneLoopPaused(false)
        resumeLibreRadio()
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
        return session
    }

    /// The files the watch loop reads. Pump history, carbs and glucose come from the
    /// same Core Data the iPhone loop uses. The JSON copies of those are not kept up to date.
    static func loopFiles(storage: FileStorage?) -> [String: String] {
        let names = [
            "preferences": OpenAPS.Settings.preferences,
            "settings": OpenAPS.Settings.settings,
            "basal": OpenAPS.Settings.basalProfile,
            "targets": OpenAPS.Settings.bgTargets,
            "isf": OpenAPS.Settings.insulinSensitivities,
            "carbRatios": OpenAPS.Settings.carbRatios,
            "autosens": OpenAPS.Settings.autosense,
            "tempTargets": OpenAPS.Settings.tempTargets,
            "profile": OpenAPS.Settings.profile,
            "reservoir": OpenAPS.Monitor.reservoir,
            "trioVariables": OpenAPS.Monitor.trio_custom_oref_variables,
            "trioSettings": OpenAPS.Trio.settings
        ]
        var files: [String: String] = [:]
        for (key, name) in names {
            files[key] = storage?.retrieveRaw(name) ?? ""
        }
        let live = liveAlgorithmInputs(smoothGlucose: files["trioSettings"]?.contains("\"smoothGlucose\" : true") == true
            || files["trioSettings"]?.contains("\"smoothGlucose\":true") == true)
        if !live.pump.isEmpty { files["pumpHistory"] = live.pump }
        if !live.carbs.isEmpty { files["carbHistory"] = live.carbs }
        if !live.glucose.isEmpty { files["glucoseHistory"] = live.glucose }
        let presets = livePresets()
        files["overridePresets"] = presets.overrides
        files["tempTargetPresets"] = presets.targets
        return files
    }

    private static func livePresets() -> (overrides: String, targets: String) {
        let context = CoreDataStack.shared.newTaskContext()
        var overrides = "[]"
        var targets = "[]"
        context.performAndWait {
            let overrideRequest = OverrideStored.fetchRequest()
            overrideRequest.predicate = NSPredicate(format: "isPreset == YES")
            let overrideRows = (try? context.fetch(overrideRequest)) ?? []
            overrides = encodeJSON(overrideRows.map { row in
                OverridePresetCopy(
                    name: row.name ?? "Override",
                    percentage: row.percentage,
                    duration: row.duration?.doubleValue ?? 0,
                    indefinite: row.indefinite,
                    target: row.target?.doubleValue ?? 0,
                    smbIsOff: row.smbIsOff,
                    isf: row.isf,
                    cr: row.cr,
                    isfAndCr: row.isfAndCr,
                    advancedSettings: row.advancedSettings,
                    smbMinutes: row.smbMinutes?.doubleValue ?? 0,
                    uamMinutes: row.uamMinutes?.doubleValue ?? 0,
                    start: row.start?.doubleValue ?? 0,
                    end: row.end?.doubleValue ?? 0,
                    smbIsScheduledOff: row.smbIsScheduledOff
                )
            })
            let targetRequest = TempTargetStored.fetchRequest()
            targetRequest.predicate = NSPredicate(format: "isPreset == YES")
            let targetRows = (try? context.fetch(targetRequest)) ?? []
            targets = encodeJSON(targetRows.map { row in
                TempTargetPresetCopy(
                    name: row.name ?? "Temp-Ziel",
                    target: row.target?.doubleValue ?? 0,
                    duration: row.duration?.doubleValue ?? 0,
                    halfBasalTarget: row.halfBasalTarget?.doubleValue ?? 160
                )
            })
        }
        return (overrides, targets)
    }

    private static func liveAlgorithmInputs(smoothGlucose: Bool) -> (pump: String, carbs: String, glucose: String) {
        let context = CoreDataStack.shared.newTaskContext()
        var pump = ""
        var carbs = ""
        var glucose = ""
        context.performAndWait {
            let pumpRequest = PumpEventStored.fetchRequest()
            pumpRequest.predicate = NSPredicate.pumpHistoryLast1440Minutes
            let pumpRows = (try? context.fetch(pumpRequest)) ?? []
            let orphaned = orphanedResumeIDs(in: context)
            let events = OpenAPS.nativePumpHistory(
                pumpRows.map(\.objectID),
                orphanedResumes: orphaned,
                from: context
            )
            pump = encodeJSON(events)

            let carbRequest = CarbEntryStored.fetchRequest()
            carbRequest.predicate = NSPredicate.predicateForOneDayAgo
            let carbRows = (try? context.fetch(carbRequest)) ?? []
            carbs = encodeJSON(carbRows.map { BaseCarbsStorage.mapToCarbsEntry($0) })

            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let glucoseRequest = GlucoseStored.fetchRequest()
            glucoseRequest.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            let glucoseRows = (try? context.fetch(glucoseRequest)) ?? []
            let rounding = NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0, raiseOnExactness: false,
                raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
            )
            glucose = encodeJSON(glucoseRows.map {
                BaseGlucoseStorage.mapToBloodGlucose($0, shouldSmoothGlucose: smoothGlucose, roundingBehavior: rounding)
            })
        }
        return (pump, carbs, glucose)
    }

    private static func orphanedResumeIDs(in context: NSManagedObjectContext) -> [NSManagedObjectID] {
        let request = PumpEventStored.fetchRequest()
        request.predicate = NSPredicate.pumpHistoryLast48h
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        let rows = ((try? context.fetch(request)) ?? []).filter {
            $0.type == PumpEventStored.EventType.pumpSuspend.rawValue
                || $0.type == PumpEventStored.EventType.pumpResume.rawValue
        }
        var orphaned: [PumpEventStored] = []
        if rows.first?.type == PumpEventStored.EventType.pumpResume.rawValue, let first = rows.first {
            orphaned.append(first)
        }
        for pair in zip(rows, rows.dropFirst()) {
            guard let previous = pair.0.timestamp, let current = pair.1.timestamp else { continue }
            let gap = current.timeIntervalSince(previous)
            if pair.1.type == PumpEventStored.EventType.pumpResume.rawValue,
               pair.0.type != PumpEventStored.EventType.pumpSuspend.rawValue || gap > 24 * 3600
            {
                orphaned.append(pair.1)
            }
        }
        return orphaned.map(\.objectID)
    }

    private struct OverridePresetCopy: Encodable {
        var name: String
        var percentage: Double
        var duration: Double
        var indefinite: Bool
        var target: Double
        var smbIsOff: Bool
        var isf: Bool
        var cr: Bool
        var isfAndCr: Bool
        var advancedSettings: Bool
        var smbMinutes: Double
        var uamMinutes: Double
        var start: Double
        var end: Double
        var smbIsScheduledOff: Bool
    }

    private struct TempTargetPresetCopy: Encodable {
        var name: String
        var target: Double
        var duration: Double
        var halfBasalTarget: Double
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .customISO8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func collectSnapshot(
        pump: Any?,
        cgm: Any?,
        iob: Double,
        cob: Double,
        maxBolus: Double,
        maxIOB: Double,
        rheosBasal: [Double],
        rheosISF: [Double],
        rheosCarbRatio: [Double],
        loopFiles: [String: String],
        glucose: Double?
    ) -> HandyFrei.Snapshot {
        var snapshot = HandyFrei.Snapshot(
            iob: iob, cob: cob, maxBolus: maxBolus, maxIOB: maxIOB,
            rheosBasal: rheosBasal, rheosISF: rheosISF, rheosCarbRatio: rheosCarbRatio,
            loopFiles: loopFiles, glucose: glucose
        )
        snapshot.mealPresets = mealPresets()
        if let medtrum = pump as? MedtrumPumpManager {
            let state = medtrum.state
            snapshot.pumpSerial = state.pumpSN.base64EncodedString()
            snapshot.sessionToken = state.sessionToken.base64EncodedString()
            snapshot.backupSessionToken = state.backupSessionToken.base64EncodedString()
            snapshot.patchId = state.patchId.base64EncodedString()
            snapshot.patchActivatedAt = state.patchActivatedAt
            snapshot.patchExpiresAt = state.patchExpiresAt
        }
        if let libre = cgm as? LibreLoopCGMManager {
            let state = libre.state
            snapshot.sensorSerial = state.sensorSerial
            snapshot.bleAddress = state.bleAddress
            snapshot.sensorPeripheralID = state.peripheralID?.uuidString
            snapshot.blePIN = state.blePIN?.base64EncodedString()
            snapshot.sensorActivatedAt = state.activatedAt
            snapshot.wearDurationMinutes = state.wearDurationMinutes
            snapshot.warmupDurationMinutes = state.warmupDurationMinutes
            if let serial = state.sensorSerial, !serial.isEmpty,
               let keys = HandyFreiKeyCopy.read(serial: serial),
               let phase5 = keys.phase5, !phase5.isEmpty
            {
                snapshot.kEnc = keys.kEnc.base64EncodedString()
                snapshot.ivEnc = keys.ivEnc.base64EncodedString()
                snapshot.phase5RawKey = phase5.base64EncodedString()
                if let receiver = keys.receiverID {
                    snapshot.receiverID = String(receiver)
                }
            } else {
                snapshot.refusal = "Phase-5-Schlüssel fehlt. Handy-frei startet nicht. Die Kopplung bleibt auf dem iPhone."
            }
        }
        return snapshot
    }

    static func mealPresets() -> [HandyFrei.MealPreset] {
        let context = CoreDataStack.shared.newTaskContext()
        var presets: [HandyFrei.MealPreset] = []
        context.performAndWait {
            let request = MealPresetStored.fetchRequest()
            let found = (try? context.fetch(request)) ?? []
            presets = found.map { item in
                HandyFrei.MealPreset(
                    id: item.objectID.uriRepresentation().absoluteString,
                    name: item.dish ?? "Mahlzeit",
                    carbs: item.carbs?.doubleValue ?? 0,
                    fat: item.fat?.doubleValue ?? 0,
                    protein: item.protein?.doubleValue ?? 0
                )
            }
        }
        return presets
    }

    private static func storeCarbs(_ entries: [[String: Any]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            for entry in entries where (entry["kind"] as? String) == "carb" || (entry["kind"] as? String) == "fpu" {
                let grams = (entry["grams"] as? NSNumber)?.doubleValue ?? (entry["units"] as? NSNumber)?.doubleValue ?? 0
                let fat = (entry["fat"] as? NSNumber)?.doubleValue ?? 0
                let protein = (entry["protein"] as? NSNumber)?.doubleValue ?? 0
                guard grams > 0 || fat > 0 || protein > 0 else { continue }
                let date = Date(timeIntervalSince1970: (entry["date"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
                let idString = entry["id"] as? String ?? ""
                let uuid = UUID(uuidString: idString) ?? UUID()
                let byID = CarbEntryStored.fetchRequest()
                byID.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                if let found = try? context.fetch(byID), !found.isEmpty { continue }
                let windowStart = date.addingTimeInterval(-180)
                let windowEnd = date.addingTimeInterval(180)
                let near = CarbEntryStored.fetchRequest()
                near.predicate = NSPredicate(format: "date >= %@ AND date <= %@", windowStart as NSDate, windowEnd as NSDate)
                let sameMeal = (try? context.fetch(near))?.contains { row in
                    abs(row.carbs - grams) < 0.1 && abs(row.fat - fat) < 0.1 && abs(row.protein - protein) < 0.1
                } ?? false
                if sameMeal { continue }
                let row = CarbEntryStored(context: context)
                row.id = uuid
                row.carbs = grams
                row.fat = fat
                row.protein = protein
                row.date = date
                row.note = entry["name"] as? String ?? "Via Watch"
                row.isFPU = (entry["kind"] as? String) == "fpu"
                if let parent = entry["fpuID"] as? String, let fpu = UUID(uuidString: parent) {
                    row.fpuID = fpu
                }
                row.isUploadedToNS = false
                row.isUploadedToHealth = false
                row.isUploadedToTidepool = false
            }
            try? context.save()
        }
    }

    private static func storeGlucose(_ entries: [[String: Any]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            for entry in entries where (entry["kind"] as? String) == "glucose" {
                let mgdl = (entry["mgdl"] as? NSNumber)?.intValue ?? 0
                guard mgdl > 0 else { continue }
                let date = Date(timeIntervalSince1970: (entry["date"] as? NSNumber)?.doubleValue ?? 0)
                let near = GlucoseStored.fetchRequest()
                near.predicate = NSPredicate(
                    format: "date >= %@ AND date <= %@",
                    date.addingTimeInterval(-3.5 * 60) as NSDate,
                    date.addingTimeInterval(3.5 * 60) as NSDate
                )
                if let found = try? context.fetch(near), !found.isEmpty { continue }
                let row = GlucoseStored(context: context)
                row.id = UUID()
                row.date = date
                row.glucose = Int16(mgdl)
                row.isManual = false
                row.isUploadedToNS = false
                row.isUploadedToHealth = false
                row.isUploadedToTidepool = false
            }
            try? context.save()
        }
    }

    private static func storeLoopStates(_ entries: [[String: Any]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            for entry in entries where (entry["kind"] as? String) == "determination" {
                guard let iob = entry["iob"] as? NSNumber, let cob = entry["cob"] as? NSNumber else { continue }
                let date = Date(timeIntervalSince1970: (entry["date"] as? NSNumber)?.doubleValue ?? 0)
                let existing = OrefDetermination.fetchRequest()
                existing.predicate = NSPredicate(format: "deliverAt == %@", date as NSDate)
                if let found = try? context.fetch(existing), !found.isEmpty { continue }
                let row = OrefDetermination(context: context)
                row.id = UUID()
                row.deliverAt = date
                row.timestamp = date
                row.iob = NSDecimalNumber(value: iob.doubleValue)
                row.cob = Int16(min(max(cob.intValue, 0), Int(Int16.max)))
                row.glucose = NSDecimalNumber(value: (entry["mgdl"] as? NSNumber)?.intValue ?? 0)
                row.reason = entry["text"] as? String
                row.enacted = true
                row.received = true
                row.isUploadedToNS = false
            }
            try? context.save()
        }
    }

    private static func storeAdjustments(_ entries: [[String: Any]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            for entry in entries {
                let kind = entry["kind"] as? String ?? ""
                let date = Date(timeIntervalSince1970: (entry["date"] as? NSNumber)?.doubleValue ?? 0)
                guard date.timeIntervalSince1970 > 1 else { continue }
                if kind == "override" {
                    let name = entry["name"] as? String ?? "Override"
                    let existing = OverrideStored.fetchRequest()
                    existing.predicate = NSPredicate(format: "name == %@ AND date >= %@ AND date <= %@", name, date.addingTimeInterval(-120) as NSDate, date.addingTimeInterval(120) as NSDate)
                    if let found = try? context.fetch(existing), !found.isEmpty { continue }
                    let row = OverrideStored(context: context)
                    row.id = UUID().uuidString
                    row.name = name
                    row.date = date
                    row.percentage = (entry["percentage"] as? NSNumber)?.doubleValue ?? 100
                    row.duration = NSDecimalNumber(value: (entry["minutes"] as? NSNumber)?.doubleValue ?? 0)
                    row.indefinite = row.duration?.doubleValue == 0
                    row.enabled = true
                    row.isPreset = false
                    row.isUploadedToNS = false
                    row.smbIsOff = false
                    row.isf = false
                    row.cr = false
                    row.isfAndCr = false
                    row.advancedSettings = false
                    row.smbIsScheduledOff = false
                } else if kind == "overrideStop" {
                    let recent = OverrideStored.fetchRequest()
                    recent.predicate = NSPredicate(format: "isPreset == NO AND enabled == YES")
                    recent.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                    recent.fetchLimit = 1
                    if let row = (try? context.fetch(recent))?.first {
                        row.enabled = false
                    }
                } else if kind == "tempTarget" {
                    let name = entry["name"] as? String ?? "Temp-Ziel"
                    let existing = TempTargetStored.fetchRequest()
                    existing.predicate = NSPredicate(format: "name == %@ AND date >= %@ AND date <= %@", name, date.addingTimeInterval(-120) as NSDate, date.addingTimeInterval(120) as NSDate)
                    if let found = try? context.fetch(existing), !found.isEmpty { continue }
                    let row = TempTargetStored(context: context)
                    row.id = UUID()
                    row.name = name
                    row.date = date
                    row.target = NSDecimalNumber(value: (entry["target"] as? NSNumber)?.doubleValue ?? 0)
                    row.duration = NSDecimalNumber(value: (entry["minutes"] as? NSNumber)?.doubleValue ?? 0)
                    row.halfBasalTarget = 160
                    row.enabled = true
                    row.isPreset = false
                    row.isUploadedToNS = false
                    row.enteredBy = "watch"
                } else if kind == "tempTargetStop" {
                    let row = TempTargetStored(context: context)
                    row.id = UUID()
                    row.name = "Cancel"
                    row.date = date
                    row.duration = 0
                    row.target = 0
                    row.enabled = true
                    row.isPreset = false
                    row.isUploadedToNS = false
                    row.enteredBy = "watch"
                }
            }
            try? context.save()
        }
    }

    private static func storeDeliveries(_ entries: [[String: Any]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            for entry in entries {
                let kind = entry["kind"] as? String ?? ""
                guard kind == "temp" || kind == "bolus" else { continue }
                let date = Date(timeIntervalSince1970: (entry["date"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
                let units = (entry["units"] as? NSNumber)?.doubleValue ?? 0
                let minutes = (entry["minutes"] as? NSNumber)?.intValue ?? 0
                let sync = "handyfrei-\(Int(date.timeIntervalSince1970))-\(kind)"
                let request = PumpEventStored.fetchRequest()
                request.predicate = NSPredicate(format: "syncIdentifier == %@", sync)
                if let found = try? context.fetch(request), !found.isEmpty { continue }
                let windowStart = date.addingTimeInterval(-180)
                let windowEnd = date.addingTimeInterval(180)
                if kind == "temp" {
                    let near = PumpEventStored.fetchRequest()
                    near.predicate = NSPredicate(
                        format: "type == %@ AND timestamp >= %@ AND timestamp <= %@",
                        PumpEventStored.EventType.tempBasal.rawValue,
                        windowStart as NSDate,
                        windowEnd as NSDate
                    )
                    let sameRate = (try? context.fetch(near))?.contains { row in
                        abs((row.tempBasal?.rate?.doubleValue ?? -999) - units) < 0.051
                    } ?? false
                    if sameRate { continue }
                } else {
                    let near = PumpEventStored.fetchRequest()
                    near.predicate = NSPredicate(
                        format: "(type == %@ OR type == %@) AND timestamp >= %@ AND timestamp <= %@",
                        PumpEventStored.EventType.bolus.rawValue,
                        PumpEventStored.EventType.smb.rawValue,
                        windowStart as NSDate,
                        windowEnd as NSDate
                    )
                    let sameAmount = (try? context.fetch(near))?.contains { row in
                        abs((row.bolus?.amount?.doubleValue ?? -999) - units) < 0.051
                    } ?? false
                    if sameAmount { continue }
                }
                let row = PumpEventStored(context: context)
                row.id = UUID().uuidString
                row.timestamp = date
                row.syncIdentifier = sync
                row.isMutable = false
                row.isUploadedToNS = false
                row.isUploadedToHealth = false
                row.isUploadedToTidepool = false
                if kind == "bolus" {
                    row.type = PumpEventStored.EventType.smb.rawValue
                    let bolus = BolusStored(context: context)
                    bolus.pumpEvent = row
                    bolus.amount = NSDecimalNumber(value: units)
                    bolus.programmedAmount = NSDecimalNumber(value: units)
                    bolus.isSMB = true
                    bolus.isExternal = false
                } else {
                    row.type = PumpEventStored.EventType.tempBasal.rawValue
                    let temp = TempBasalStored(context: context)
                    temp.pumpEvent = row
                    temp.rate = NSDecimalNumber(value: units)
                    temp.duration = Int16(min(max(minutes, 0), Int(Int16.max)))
                    temp.startDate = date
                    temp.endDate = date.addingTimeInterval(TimeInterval(minutes * 60))
                    temp.tempType = TempType.absolute.rawValue
                    temp.isScheduledBasal = false
                }
            }
            try? context.save()
        }
    }

    private static func store(_ session: HandyFrei.Session) {
        UserDefaults.standard.set(session.note, forKey: statusKey)
    }

    private static weak var handedLibre: LibreLoopCGMManager?

    /// Stops the phone connecting. The sensor session, serial, and keychain item stay.
    private static func releaseLibreRadio(_ cgm: Any?) {
        guard let libre = cgm as? LibreLoopCGMManager else { return }
        handedLibre = libre
        libre.releaseRadioKeepingPairing()
    }

    private static func resumeLibreRadio() {
        handedLibre?.resumeRadioAfterHandoff()
        handedLibre = nil
    }

    private static func send(_ session: HandyFrei.Session, snapshot: HandyFrei.Snapshot?, kind: String) {
        guard WCSession.isSupported() else { return }
        let link = WCSession.default
        guard link.activationState == .activated else { return }
        var payload: [String: Any] = [
            "kind": kind,
            "note": session.note,
            "ownsRadio": session.watchOwnsRadio
        ]
        if let snapshot {
            payload["shadow"] = HandyFrei.shadowLine(glucose: snapshot.glucose, iob: snapshot.iob)
            payload["snapshot"] = snapshot.plist
        }
        let message = ["handyFrei": payload]
        if link.isReachable {
            link.sendMessage(message, replyHandler: nil) { _ in
                link.transferUserInfo(message)
            }
        } else {
            link.transferUserInfo(message)
        }
    }
}

/// Reads the Libre session item. It never deletes it.
enum HandyFreiKeyCopy {
    static let service = "org.loopkit.LibreLoop.sessionKeys"

    struct Keys {
        var kEnc: Data
        var ivEnc: Data
        var phase5: Data?
        var receiverID: UInt32?
    }

    static func read(serial: String) -> Keys? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serial,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Keys? {
        if data.count >= 45, data.first == 0x03 || data.first == 0x04 {
            let receiver = UInt32(data[41])
                | (UInt32(data[42]) << 8)
                | (UInt32(data[43]) << 16)
                | (UInt32(data[44]) << 24)
            return Keys(
                kEnc: data.subdata(in: 1 ..< 17),
                ivEnc: data.subdata(in: 17 ..< 25),
                phase5: data.subdata(in: 25 ..< 41),
                receiverID: receiver
            )
        }
        if data.count == 41, data.first == 0x02 {
            return Keys(
                kEnc: data.subdata(in: 1 ..< 17),
                ivEnc: data.subdata(in: 17 ..< 25),
                phase5: data.subdata(in: 25 ..< 41),
                receiverID: nil
            )
        }
        return nil
    }
}

final class HandyFreiBluetoothWatch: NSObject, CBCentralManagerDelegate {
    static let shared = HandyFreiBluetoothWatch()
    private var central: CBCentralManager?

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
        }
    }

    var isPoweredOff: Bool { central?.state == .poweredOff }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            HandyFreiPhone.bluetoothIsOff()
        }
    }
}
