//
//  CreateCommandHandlers.swift
//  GitBranchStatus
//
//  Created by Thomas Evensen on 26/07/2026.
//

import Foundation
import ProcessCommand

@MainActor
struct CreateCommandHandlers {
    func createCommandHandlers(
        processTermination: @escaping ([String]?, Bool) -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void
    ) -> ProcessHandlersCommand {
        ProcessHandlersCommand(
            processtermination: processTermination,
            checklineforerror: { _ in },
            updateprocess: updateProcess,
            propogateerror: propagateError,
            logger: { _, _ in },
            rsyncui: false
        )
    }
}
