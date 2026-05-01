<script lang="ts">
  import { onMount } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';

  type ReceiverStatus = {
    running: boolean;
    srt_port: number;
    obs_udp_port: number;
    discovery_port: number;
    client_discovery_port: number;
    tailscale_ip?: string;
    summary: string;
  };

  let status: ReceiverStatus | null = null;
  let busy = false;
  let logs: string[] = [];

  function addLog(message: string) {
    const stamp = new Date().toLocaleTimeString();
    logs = [`${stamp}  ${message}`, ...logs].slice(0, 80);
  }

  async function refreshStatus() {
    try {
      status = await invoke<ReceiverStatus>('receiver_status');
    } catch (error) {
      addLog(`Status error: ${error}`);
    }
  }

  async function runAction(label: string, command: string) {
    busy = true;
    addLog(`${label}...`);
    try {
      const output = await invoke<string>(command);
      addLog(output || `${label} completed.`);
      await refreshStatus();
    } catch (error) {
      addLog(`${label} failed: ${error}`);
    } finally {
      busy = false;
    }
  }

  async function runDoctor() {
    busy = true;
    addLog('Running workstation doctor...');
    try {
      const output = await invoke<string>('run_doctor');
      for (const line of output.split(/\r?\n/).filter(Boolean).reverse()) {
        addLog(line);
      }
      await refreshStatus();
    } catch (error) {
      addLog(`Doctor failed: ${error}`);
    } finally {
      busy = false;
    }
  }

  onMount(() => {
    refreshStatus();
    const timer = window.setInterval(refreshStatus, 3000);
    return () => window.clearInterval(timer);
  });
</script>

<main class="min-h-screen bg-[#101114] text-zinc-100">
  <section class="mx-auto grid min-h-screen max-w-6xl grid-rows-[auto_1fr] gap-6 px-6 py-6">
    <header class="flex flex-wrap items-center justify-between gap-4 border-b border-zinc-800 pb-5">
      <div>
        <h1 class="text-2xl font-semibold tracking-normal">Project O Stream Desktop</h1>
        <p class="mt-1 text-sm text-zinc-400">Tauri + Svelte controller for receiver, OBS handoff, and workstation checks</p>
      </div>

      <div class="flex items-center gap-3">
        <span class="h-2.5 w-2.5 rounded-full {status?.running ? 'bg-emerald-400' : 'bg-zinc-600'}"></span>
        <span class="text-sm font-semibold">{status?.running ? 'Receiver Running' : 'Receiver Stopped'}</span>
      </div>
    </header>

    <div class="grid gap-6 lg:grid-cols-[360px_1fr]">
      <aside class="space-y-4">
        <section class="border border-zinc-800 bg-zinc-950/60 p-4">
          <h2 class="text-sm font-semibold uppercase text-zinc-400">Controls</h2>
          <div class="mt-4 grid gap-3">
            <button
              class="h-11 bg-emerald-500 px-4 text-sm font-bold text-zinc-950 disabled:cursor-not-allowed disabled:opacity-45"
              disabled={busy || status?.running}
              on:click={() => runAction('Start receiver', 'start_receiver')}
            >
              Start Receiver
            </button>
            <button
              class="h-11 border border-red-500/40 bg-red-500/10 px-4 text-sm font-bold text-red-200 disabled:cursor-not-allowed disabled:opacity-45"
              disabled={busy || !status?.running}
              on:click={() => runAction('Stop receiver', 'stop_receiver')}
            >
              Stop Receiver
            </button>
            <button
              class="h-11 border border-zinc-700 bg-zinc-900 px-4 text-sm font-bold disabled:cursor-not-allowed disabled:opacity-45"
              disabled={busy}
              on:click={runDoctor}
            >
              Run Doctor
            </button>
            <button
              class="h-11 border border-zinc-700 bg-zinc-900 px-4 text-sm font-bold disabled:cursor-not-allowed disabled:opacity-45"
              disabled={busy}
              on:click={() => runAction('Launch OBS', 'launch_obs')}
            >
              Launch OBS
            </button>
          </div>
        </section>

        <section class="border border-zinc-800 bg-zinc-950/60 p-4">
          <h2 class="text-sm font-semibold uppercase text-zinc-400">Receiver</h2>
          <dl class="mt-4 grid gap-3 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-zinc-500">Summary</dt>
              <dd class="text-right">{status?.summary ?? 'Checking...'}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-zinc-500">Tailscale</dt>
              <dd class="font-mono text-sky-300">{status?.tailscale_ip ?? 'not detected'}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-zinc-500">SRT</dt>
              <dd class="font-mono">0.0.0.0:{status?.srt_port ?? 7070}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-zinc-500">OBS UDP</dt>
              <dd class="font-mono">127.0.0.1:{status?.obs_udp_port ?? 15000}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-zinc-500">Discovery</dt>
              <dd class="font-mono">{status?.discovery_port ?? 7071}/{status?.client_discovery_port ?? 7072}</dd>
            </div>
          </dl>
        </section>

        <section class="border border-zinc-800 bg-zinc-950/60 p-4">
          <h2 class="text-sm font-semibold uppercase text-zinc-400">3.0 Release</h2>
          <ul class="mt-4 space-y-2 text-sm text-zinc-300">
            <li>Full platform parity (Android/iOS SRT)</li>
            <li>Real receiver lifecycle controls</li>
            <li>Workstation doctor output inside the app</li>
            <li>Tailscale and port visibility</li>
            <li>Desktop-only branch metadata</li>
          </ul>
        </section>
      </aside>

      <section class="flex min-h-[560px] flex-col border border-zinc-800 bg-black">
        <div class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
          <h2 class="text-sm font-semibold uppercase text-zinc-400">Operational Log</h2>
          <button class="text-xs text-zinc-500 hover:text-zinc-200" on:click={() => (logs = [])}>Clear</button>
        </div>
        <div class="flex-1 overflow-y-auto p-4 font-mono text-sm">
          {#if logs.length === 0}
            <p class="text-zinc-600">No activity yet. Start the receiver or run doctor.</p>
          {:else}
            {#each logs as log}
              <div class="border-b border-zinc-900 py-2 text-zinc-300">{log}</div>
            {/each}
          {/if}
        </div>
      </section>
    </div>
  </section>
</main>
