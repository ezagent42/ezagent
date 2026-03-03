mod commands;
mod config;
mod output;

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
    /// Room management
    #[command(name = "room")]
    Room {
        #[command(subcommand)]
        action: RoomCommands,
    },
    /// List all rooms
    Rooms {
        /// Output as JSON
        #[arg(long)]
        json: bool,
        /// Output room IDs only, one per line
        #[arg(long)]
        quiet: bool,
    },
}

#[derive(Subcommand)]
enum IdentityCommands {
    /// Show current identity information
    Whoami,
}

#[derive(Subcommand)]
enum RoomCommands {
    /// Create a new room
    Create {
        /// Human-readable room name
        #[arg(long)]
        name: String,
    },
    /// Show room details
    Show {
        /// Room ID to inspect
        room_id: String,
    },
    /// Invite a member to a room
    Invite {
        /// Room ID to invite into
        room_id: String,
        /// Entity ID of the invitee (e.g., @bob:relay.example.com)
        #[arg(long)]
        entity: String,
    },
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
        Commands::Room { action } => match action {
            RoomCommands::Create { name } => commands::room::create(&name),
            RoomCommands::Show { room_id } => commands::room::show(&room_id),
            RoomCommands::Invite { room_id, entity } => {
                commands::room::invite(&room_id, &entity)
            }
        },
        Commands::Rooms { json, quiet } => commands::room::list(json, quiet),
    };
    process::exit(exit_code);
}
