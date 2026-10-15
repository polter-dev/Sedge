// The Mac evaluation command line. Each first word picks a command.
//
//   swift run --package-path Packages/SedgeCore sedge-eval backtest --cutoff 2026-06-16 --days 14 [--no-reconciliation]
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "backtest":
    try backtest(Array(arguments.dropFirst()))
default:
    print("Usage: sedge-eval backtest --cutoff YYYY-MM-DD [--cutoff ...] [--days 14] [--no-reconciliation] [--out file.csv]")
    exit(2)
}
