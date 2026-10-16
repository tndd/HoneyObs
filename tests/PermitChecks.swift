import Foundation
@main struct Checks {
 static func main() {
  var now = 100.0
  let permission = ForwardingPermit(confirmedAt:now,clock:{now})
  now=102; precondition(permission.renew(confirmedAt:100))
  now=103; precondition(!permission.valid)
  precondition(!permission.renew(confirmedAt:now))
  now=1; precondition(!permission.valid)
  let fresh = ForwardingPermit(confirmedAt:now,clock:{now})
  precondition(fresh.valid); fresh.revoke(); precondition(!fresh.renew(confirmedAt:now))
  print("上流の古い確認を延命しない・期限境界・失効不可逆・別許可の分離: PASS")
 }
}
