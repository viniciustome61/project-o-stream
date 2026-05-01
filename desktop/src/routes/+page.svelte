<script lang="ts">
  import { onMount } from 'svelte';
  import { Command } from '@tauri-apps/plugin-shell';
  import { invoke } from '@tauri-apps/api/core';

  let status = 'idle'; // idle, running, error
  let logs: string[] = [];
  let receiverProcess: any = null;

  async function startReceiver() {
    try {
      status = 'running';
      addLog('Starting Project O Receiver...');
      
      // In a real app, we'd use Command.create('powershell', ...)
      // and handle scopes. For now, let's just mock the UI visuals.
      addLog('SRT Listener: srt://0.0.0.0:7070');
      addLog('Discovery: active on UDP 7071/7072');
    } catch (e) {
      status = 'error';
      addLog(`Error: ${e}`);
    }
  }

  function stopReceiver() {
    status = 'idle';
    addLog('Receiver stopped.');
  }

  function addLog(msg: string) {
    logs = [msg, ...logs].slice(0, 50);
  }
</script>

<main class="min-h-screen bg-[#0f1115] text-white p-8 font-sans selection:bg-purple-500/30">
  <!-- Background Glow -->
  <div class="fixed top-0 left-0 w-full h-full overflow-hidden pointer-events-none z-0">
    <div class="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] bg-purple-600/10 blur-[120px] rounded-full"></div>
    <div class="absolute bottom-[-10%] right-[-10%] w-[40%] h-[40%] bg-blue-600/10 blur-[120px] rounded-full"></div>
  </div>

  <div class="relative z-10 max-w-4xl mx-auto">
    <!-- Header -->
    <header class="flex justify-between items-center mb-12">
      <div>
        <h1 class="text-3xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-purple-400 to-blue-400">
          Project O Stream
        </h1>
        <p class="text-gray-400 mt-1 text-sm tracking-wide uppercase">Desktop Controller • v0.1.0</p>
      </div>
      
      <div class="flex items-center gap-3">
        <div class="flex flex-col items-end">
          <span class="text-xs text-gray-500 uppercase font-semibold">Status</span>
          <div class="flex items-center gap-2">
            <div class="w-2 h-2 rounded-full {status === 'running' ? 'bg-green-500 animate-pulse' : 'bg-gray-600'}"></div>
            <span class="text-sm font-medium">{status.toUpperCase()}</span>
          </div>
        </div>
      </div>
    </header>

    <!-- Main Grid -->
    <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
      
      <!-- Control Panel -->
      <div class="md:col-span-1 space-y-6">
        <div class="bg-white/5 border border-white/10 p-6 rounded-2xl backdrop-blur-xl shadow-2xl">
          <h2 class="text-lg font-semibold mb-4 flex items-center gap-2">
            <svg xmlns="http://www.w3.org/2000/svg" class="w-5 h-5 text-purple-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v4"/><path d="m16.2 4.8 2.9 2.9"/><path d="M19.2 12h4.8"/><path d="m16.2 19.2 2.9-2.9"/><path d="M12 18v4"/><path d="m4.8 19.2 2.9-2.9"/><path d="M0 12h4.8"/><path d="m4.8 4.8 2.9 2.9"/></svg>
            Controls
          </h2>
          
          <div class="space-y-3">
            {#if status !== 'running'}
              <button 
                on:click={startReceiver}
                class="w-full py-3 bg-gradient-to-r from-purple-600 to-blue-600 hover:from-purple-500 hover:to-blue-500 rounded-xl font-bold transition-all shadow-lg shadow-purple-900/20 active:scale-[0.98]"
              >
                Start Receiver
              </button>
            {:else}
              <button 
                on:click={stopReceiver}
                class="w-full py-3 bg-red-500/10 border border-red-500/20 hover:bg-red-500/20 text-red-400 rounded-xl font-bold transition-all active:scale-[0.98]"
              >
                Stop Receiver
              </button>
            {/if}
            
            <button class="w-full py-3 bg-white/5 hover:bg-white/10 border border-white/5 rounded-xl font-medium text-gray-300 transition-all text-sm">
              Launch OBS
            </button>
          </div>
        </div>

        <!-- Stats Card -->
        <div class="bg-white/5 border border-white/10 p-6 rounded-2xl backdrop-blur-xl">
          <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-widest mb-4">Network Info</h2>
          <div class="space-y-4">
            <div class="flex justify-between items-center">
              <span class="text-xs text-gray-500">SRT Port</span>
              <span class="text-sm font-mono">7070</span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-xs text-gray-500">OBS UDP</span>
              <span class="text-sm font-mono">15000</span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-xs text-gray-500">Tailscale IP</span>
              <span class="text-sm font-mono text-blue-400">100.x.y.z</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Logs/Console -->
      <div class="md:col-span-2">
        <div class="bg-black/40 border border-white/10 rounded-2xl h-[450px] flex flex-col overflow-hidden backdrop-blur-md">
          <div class="bg-white/5 px-6 py-3 border-b border-white/10 flex justify-between items-center">
            <span class="text-sm font-medium text-gray-400">Terminal Log</span>
            <div class="flex gap-1.5">
              <div class="w-2.5 h-2.5 rounded-full bg-red-500/20"></div>
              <div class="w-2.5 h-2.5 rounded-full bg-yellow-500/20"></div>
              <div class="w-2.5 h-2.5 rounded-full bg-green-500/20"></div>
            </div>
          </div>
          <div class="p-6 overflow-y-auto flex flex-col-reverse gap-2 flex-grow scrollbar-hide">
            {#each logs as log}
              <div class="text-sm font-mono">
                <span class="text-purple-500 mr-2">›</span>
                <span class="text-gray-300">{log}</span>
              </div>
            {/each}
            {#if logs.length === 0}
              <div class="text-gray-600 font-mono text-sm italic">Waiting for activity...</div>
            {/if}
          </div>
        </div>
      </div>

    </div>

    <!-- Footer Info -->
    <footer class="mt-12 flex justify-center items-center gap-8 text-xs text-gray-600 uppercase tracking-widest">
      <div class="flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-green-500/50"></span>
        SRT Ready
      </div>
      <div class="flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-blue-500/50"></span>
        UDP Discovery Active
      </div>
      <div class="flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-purple-500/50"></span>
        Tailscale Encrypted
      </div>
    </footer>
  </div>
</main>

<style>
  :global(body) {
    overflow: hidden;
  }
  .scrollbar-hide::-webkit-scrollbar {
    display: none;
  }
  .scrollbar-hide {
    -ms-overflow-style: none;
    scrollbar-width: none;
  }
</style>
