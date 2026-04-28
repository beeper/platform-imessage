import PackagePlugin

@main
struct GenerateIMessageCLIVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "GenerateIMessageCLIVersion")
        let packageJSON = context.package.directory.appending("package.json")
        let output = context.pluginWorkDirectory.appending("IMessageCLIVersion.swift")

        return [
            .buildCommand(
                displayName: "Generate iMessage CLI version source",
                executable: tool.path,
                arguments: [packageJSON.string, output.string],
                inputFiles: [packageJSON],
                outputFiles: [output]
            ),
        ]
    }
}
