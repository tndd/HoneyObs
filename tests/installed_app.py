#!/usr/bin/env python3
"""導入済み.appをLaunch Servicesで起動し、自己ペネと中止を製品画面で確認する。"""
import json, os, pathlib, plistlib, shutil, socket, subprocess, sys, tempfile, time
root=pathlib.Path(__file__).resolve().parent.parent
app=pathlib.Path.home()/'Applications/HoneyObs.app'
out=root/'test-results'/('installed-app-'+time.strftime('%Y%m%d-%H%M%S'));out.mkdir(parents=True)
def read(p):
 try:return json.loads(p.read_text())
 except (FileNotFoundError,json.JSONDecodeError):return {}
def wait(fn,seconds=80):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  v=fn()
  if v:return v
  time.sleep(.1)
 raise AssertionError('確認の待機期限を超えました')
def command(run,text):
 p=run/'ui-command';wait(lambda:not p.exists(),5);p.write_text(text)
def closed(port):
 try:s=socket.create_connection(('127.0.0.1',port),.5);s.close();return False
 except OSError:return True
summary={}
for name in (sys.argv[1:] or ['complete','cancel','cancel-after-ip']):
 assert name in ['complete','cancel','cancel-after-ip']
 run=pathlib.Path(tempfile.mkdtemp(prefix='HoneyObs-installed-'+name+'-'));os.chmod(run,0o700)
 pid=None
 try:
  subprocess.run(['open','-n','-a',str(app),'--args','--test-mode','--ui-exercise-smoke','--run-directory',str(run)],cwd='/tmp',check=True)
  state=wait(lambda:(s if (s:=read(run/'state.json')).get('originPort') else None),45);pid=state['pid'];port=state['originPort']
  process=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
  assert process.startswith(str(app/'Contents/MacOS/HoneyObs')+' '),process
  assert state['supervisorPID']==0 and not state['url'] and not (run/'tunnel.log').exists()
  opened=subprocess.check_output(['lsof','-p',str(pid),'-Fn'],text=True)
  assert str(root) not in opened,'インストールしたアプリがrepo内のファイルを開いています'
  assert str(app/'Contents/Resources') in opened
  if name=='cancel-after-ip':
   wait(lambda:read(run/'exercise.json').get('sequence',0)>=12,40)
  if name!='complete':command(run,'stop')
  report=wait(lambda:read(run/'exercise-report.json'),95)
  if name=='complete':
   assert report['passed'] and len(report['cases'])==20 and report['burst']==160 and report['slowRejected']==8,report
  else:assert not report['passed'] and report.get('cancelled') and '中止' in report['failure'],report
  final=wait(lambda:(s if (s:=read(run/'state.json')).get('shutdownComplete') else None),12)
  assert not final['vmPresent'] and final['supervisorPID']==0 and closed(port)
  ui=wait(lambda:(s if (s:=read(run/'ui-state.json')).get('exerciseStage') in ['試験完了','中止','要確認'] else None),5)
  assert not ui['overflow'] and ui['routes']==0
  command(run,'resize');time.sleep(1.2);command(run,'capture')
  wait(lambda:(run/'ui-capture.png').exists(),8)
  shutil.copy(run/'ui-capture.png',out/(name+'.png'))
  assert read(run/'ui-state.json')['width']==860 and not read(run/'ui-state.json')['overflow']
  if name=='cancel-after-ip':
   assert any(e.get('ip')=='8.8.8.8' for e in read(run/'events.json').get('events',[]))
   command(run,'back')
   returned=wait(lambda:(s if (s:=read(run/'ui-state.json')).get('exerciseVisible') is False else None),5)
   assert returned['allRoutes']==0 and 'localhost' in returned['location'],returned
  summary[name]={'report':report,'state':final,'ui':ui,'executable':process,'run':str(run)}
 finally:
  if pid:
   command(run,'quit')
   wait(lambda:not subprocess.run(['kill','-0',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0,15)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());icon=app/'Contents/Resources'/(info['CFBundleIconFile']+'.icns')
assert icon.is_file() and icon.stat().st_size>10000
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
summary['icon']=str(icon);(out/'report.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print('導入済みアプリの検証: PASS',list(summary.keys()),out)
