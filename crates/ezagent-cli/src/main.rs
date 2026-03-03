mod config;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "ezagent", about = "EZAgent42 — Programmable Organization OS")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize identity and register with a relay
    Init {
        #[arg(long)]
        relay: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        ca_cert: Option<String>,
        #[arg(long)]
        force: bool,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Init { relay, name, .. } => {
            println!("TODO: init --relay {relay} --name {name}");
        }
    }
}
