use serde::Serialize;
use std::{
    path::PathBuf,
    process::{Command, Stdio},
};

#[derive(Serialize)]
struct ReceiverStatus {
    running: bool,
    srt_port: u16,
    obs_udp_port: u16,
    discovery_port: u16,
    client_discovery_port: u16,
    tailscale_ip: Option<String>,
    summary: String,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|desktop| desktop.parent())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn powershell(args: &[&str]) -> Result<String, String> {
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass"])
        .args(args)
        .current_dir(repo_root())
        .output()
        .map_err(|error| error.to_string())?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if output.status.success() {
        Ok(if stdout.is_empty() { stderr } else { stdout })
    } else {
        Err(if stderr.is_empty() { stdout } else { stderr })
    }
}

#[tauri::command]
fn receiver_status() -> Result<ReceiverStatus, String> {
    let tailscale_ip = powershell(&["-Command", "if (Get-Command tailscale -ErrorAction SilentlyContinue) { tailscale ip -4 | Select-Object -First 1 }"])
        .ok()
        .filter(|value| !value.is_empty());

    let udp = powershell(&[
        "-Command",
        "Get-NetUDPEndpoint -LocalPort 7070,7071,7072,15000 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort",
    ])
    .unwrap_or_default();

    let running = udp.lines().any(|line| line.trim() == "7070")
        || udp.lines().any(|line| line.trim() == "7071");

    Ok(ReceiverStatus {
        running,
        srt_port: 7070,
        obs_udp_port: 15000,
        discovery_port: 7071,
        client_discovery_port: 7072,
        tailscale_ip,
        summary: if running {
            "Receiver/discovery ports are active".into()
        } else {
            "Receiver is stopped".into()
        },
    })
}

#[tauri::command]
fn start_receiver() -> Result<String, String> {
    let script = repo_root().join("server").join("start-receiver.ps1");
    Command::new("powershell.exe")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(script)
        .current_dir(repo_root())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| error.to_string())?;

    Ok("Receiver start requested. Discovery will advertise on UDP 7071/7072.".into())
}

#[tauri::command]
fn stop_receiver() -> Result<String, String> {
    powershell(&[
        "-Command",
        "$ports = 7070,7071,7072,15000; $ids = @(); $ids += Get-NetUDPEndpoint -LocalPort $ports -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess; $ids += Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*start-receiver.ps1*' -or $_.CommandLine -like '*discovery-server.ps1*' -or $_.CommandLine -like '*ffmpeg*udp://127.0.0.1:15000*' } | Select-Object -ExpandProperty ProcessId; $ids | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }; 'Receiver stop requested.'",
    ])
}

#[tauri::command]
fn run_doctor() -> Result<String, String> {
    let script = repo_root().join("ops").join("doctor.ps1");
    powershell(&["-File", script.to_string_lossy().as_ref()])
}

#[tauri::command]
fn launch_obs() -> Result<String, String> {
    let script = repo_root().join("ops").join("launch-obs.ps1");
    powershell(&["-File", script.to_string_lossy().as_ref()])
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            receiver_status,
            start_receiver,
            stop_receiver,
            run_doctor,
            launch_obs
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
