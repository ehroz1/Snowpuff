// Compiles a Core ML package where Xcode's coremlcompiler isn't installed: Core ML itself can do it.
// swift scripts/compile-model.swift <model.mlpackage> <output folder>
import CoreML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: compile-model.swift <model.mlpackage> <output folder>\n".data(using: .utf8)!)
    exit(2)
}
let package = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let compiled = try MLModel.compileModel(at: package)
let destination = output.appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mlmodelc")
try? FileManager.default.removeItem(at: destination)
try FileManager.default.copyItem(at: compiled, to: destination)
