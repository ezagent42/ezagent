mod commands;
mod config;

use clap::{Parser, Subcommand};
use std::process;

#[derive(Parser)]
#[command(name = "ezagent", about = "EZAgent42 -- Programmable Organization OS")]
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
    /// Identity management
    Identity {
        #[command(subcommand)]
        action: IdentityCommands,
    },
}

#[derive(Subcommand)]
enum IdentityCommands {
    /// Show current identity information
    Whoami,
}

fn main() {
    let cli = Cli::parse();
    let exit_code = match cli.command {
        Commands::Init {
            relay,
            name,
            ca_cert,
            force,
        } => commands::init::run(&relay, &name, ca_cert.as_deref(), force),
        Commands::Identity { action } => match action {
            IdentityCommands::Whoami => commands::identity::whoami(),
        },
    };
    process::exit(exit_code);
}
