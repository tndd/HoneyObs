#!/usr/bin/env python3
"""外部公開なしで、実VM・製品Relay・製品watchdogのフリーズ境界を検証する。"""
import select
import json, os, pathlib, shutil, signal, socket, struct, subprocess, time
root=pathlib.Path(__file__).resolve().parent.parent
out=root/'test-results'/('permit-faults-'+time.strftime('%Y%m%d-%H%M%S'));out.mkdir(parents=True)
app=pathlib.Path.home()/'Applications/HoneyObs.app'
exe=app/'Contents/MacOS/HoneyObs'
def read(p):
 try:return json.loads(p.read_text())
 except (FileNotFoundError,json.JSONDecodeError):return {}
def wait(fn,seconds=15):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=fn()
  if value:return value
  time.sleep(.05)
 raise AssertionError('状態確認の待機期限を超えました')
def alive(pid):
 try:os.kill(pid,0);return True
 except ProcessLookupError:return False
def closed(port):
 try:s=socket.create_connection(('127.0.0.1',port),.3);s.close();return False
 except OSError:return True
def command(run,text):
 wait(lambda:not (run/'ui-command').exists(),5);(run/'ui-command').write_text(text)
def held(port,host):
 s=socket.create_connection(('127.0.0.1',port),1)
 s.sendall(f'POST /login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx'.encode())
 return s
summary={}
for fault in ['freeze-main','freeze-ui']:
 run=out/fault;run.mkdir(mode=0o700)
 with (run/'app.log').open('w') as log:
  process=subprocess.Popen([str(exe),'--test-mode','--ui-exercise-smoke','--run-directory',str(run)],stdout=log,stderr=log,cwd='/tmp')
  connection=None
  try:
   state=wait(lambda:(s if (s:=read(run/'state.json')).get('originPort') else None),40);port=state['originPort']
   host=wait(lambda:read(run/'test-origin.json').get('host'),5)
   connection=held(port,host);time.sleep(.1)
   assert not select.select([connection],[],[],0)[0], 'フリーズ注入前に接続が既に終了しています'
   command(run,fault);wait(lambda:not (run/'ui-command').exists(),5)
   started=time.monotonic();connection.settimeout(3.6)
   try:data=connection.recv(100)
   except ConnectionResetError:data=b''
   elapsed=time.monotonic()-started;assert data==b'',(fault,round(elapsed,3),data)
   time.sleep(max(0,3.25-(time.monotonic()-started)))
   try:
    with socket.create_connection(('127.0.0.1',port),.5) as probe:
     probe.settimeout(3);probe.sendall(f'GET /qa-after-permit-expiry HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
     try:late=probe.recv(100)
     except ConnectionResetError:late=b''
     assert late==b'', '期限切れ後の要求に応答しました'
   except ConnectionRefusedError:pass
   final=wait(lambda:(s if (s:=read(run/'state.json')).get('shutdownComplete') else None),12)
   assert not final['vmPresent'] and closed(port) and not (run/'tunnel.log').exists()
   archive=read(run/'events.json')
   summary[fault]={'connectionClosedWithin':round(elapsed,3),'state':final}
  finally:
   if connection:connection.close()
   command(run,'quit');process.wait(timeout=15)
# トンネル実行資産だけを通信しない固定プロセスへ置換。他の製品バイナリ・VMはそのまま。
fake=out/'HoneyObs.app';shutil.copytree(app,fake)
source=out/'tunnel.c';source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
subprocess.run(['cc',str(source),'-o',str(fake/'Contents/Resources/cloudflared')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(fake/'Contents/Resources/cloudflared')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['codesign','--force','--sign','-','--entitlements',str(root/'entitlements.plist'),str(fake)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for fault in ['parent-stop','guardian-stop']:
 run=out/fault;run.mkdir(mode=0o700);guardian=tunnel=0
 with (run/'app.log').open('w') as log:
  process=subprocess.Popen([str(fake/'Contents/MacOS/HoneyObs'),'--test-mode','--headless','--public','--run-directory',str(run)],stdout=log,stderr=log,cwd='/tmp')
  try:
   guard=wait(lambda:read(run/'watchdog.json'),40);guardian=guard['watchdogPID'];tunnel=guard['tunnelPID']
   state=read(run/'state.json');port=state['originPort']
   with socket.create_connection(('127.0.0.1',port),1) as s:
    s.settimeout(2);s.sendall(b'GET /qa-before-freeze HTTP/1.1\r\nHost: attacker.invalid\r\nConnection: close\r\n\r\n');assert b' 403 ' in s.recv(200)
   time.sleep(.5);target=process.pid if fault=='parent-stop' else guardian
   started=time.monotonic();os.kill(target,signal.SIGSTOP)
   if fault=='parent-stop':
    wait(lambda:not alive(tunnel),6)
    elapsed=time.monotonic()-started
    assert alive(process.pid),'観測前に親を回収してしまいました'
    os.kill(target,signal.SIGCONT)
   else:
    wait(lambda:not read(run/'state.json').get('active',True) and closed(port),4.5)
    elapsed=time.monotonic()-started
    assert alive(guardian),'SIGSTOPした監視役を観測前に回収してしまいました'
    os.kill(target,signal.SIGCONT)
   final=wait(lambda:(s if (s:=read(run/'state.json')).get('shutdownComplete') else None),12)
   assert not final['vmPresent'] and closed(port)
   wait(lambda:not alive(guardian) and not alive(tunnel),5)
   time.sleep(.4);assert read(run/'state.json')['shutdownComplete'] and closed(port)
   summary[fault]={'stoppedWithin':round(elapsed,3),'state':final,'externalTunnel':False}
  finally:
   for pid in [process.pid,guardian]:
    if pid and alive(pid):os.kill(pid,signal.SIGCONT)
   if process.poll() is None:process.terminate();process.wait(timeout=15)
   # 成否判定後の掃除。成功条件の代わりには使用しない。
   for pid in [guardian,tunnel]:
    if pid and alive(pid):os.kill(pid,signal.SIGKILL)
# 親が再送した旧フレームは延命せず、子の回収を待って終了する。
protocol=out/'replayed-frame';protocol.mkdir(mode=0o700)
with (protocol/'app.log').open('w') as log:
 process=subprocess.Popen([str(exe),'--watchdog',str(os.getpid()),str(protocol),str(fake/'Contents/Resources/cloudflared'),'unused'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log)
 frame=struct.pack('=QQ',1,time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)+2_500_000_000)
 process.stdin.write(frame);process.stdin.flush()
 assert process.stdout.read(16)==frame
 guard=wait(lambda:read(protocol/'watchdog.json'),5)
 process.stdin.write(frame);process.stdin.flush();process.wait(timeout=4)
 assert process.returncode==0 and not alive(guard['tunnelPID'])
 summary['replayed-frame']={'rejected':True,'childReaped':True}
(out/'report.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print('実VMの転送失効・既存接続閉鎖・UI/主処理/親/監視役の停止・再開不可: PASS',out)
