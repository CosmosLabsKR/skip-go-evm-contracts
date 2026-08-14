# noble-transit-burn

transit 경로를 처음부터 끝까지 실행해보는 도구. 커맨드 세 개로 구성된다.

| 커맨드 | 구간 | 하는 일 |
| --- | --- | --- |
| `burn` | Noble → Avalanche | CCTP v1 `depositForBurnWithCaller`를 만들고, 원하면 브로드캐스트 |
| `execute` | Avalanche → Injective | Circle 어테스테이션을 받아 `TransitExecutor.executeTransit` 호출 |
| `mint` | Injective 도착 | onward 어테스테이션을 받아 `MessageTransmitterV2.receiveMessage` 호출 |

CCTP hop 자체는 두 번이다(Noble→Avalanche가 v1, Avalanche→Injective가 v2). 커맨드가 셋인 이유는 두 번째
hop의 수신 쪽, 즉 Injective에서의 민팅이 별도 트랜잭션이기 때문이다.

## 트랜잭션이 담아야 하는 것

```
Noble (domain 4)                Avalanche (domain 1)                   Injective (domain 29)
  depositForBurnWithCaller  ──►  TransitExecutor.executeTransit   ──►   최종 수취인
    mintRecipient     = 예측된 TransitForwarder                          (ROUTE_MINT_RECIPIENT)
    destinationCaller = TransitExecutor
```

설계 전체를 지탱하는 필드는 두 개다.

- **`destinationCaller` = TransitExecutor** (메인넷 `0xF9701898e7a543028d47A3913BC191CaE7371334`). 이 메시지에 대해
  `receiveMessage`를 부를 수 있는 주소는 오직 이것뿐이므로, 민팅과 이어지는 재-burn은 한 트랜잭션 안에서만
  일어날 수 있다.
- **`mintRecipient` = 아직 존재하지 않는, 예측된 TransitForwarder.** 주소는
  `CREATE2(factory, keccak256(abi.encode(sender, destinationDomain, mintRecipient)), beaconInitCodeHash)` —
  라우트가 주소에 각인되어 있으므로, 여기서 이 주소를 지정하는 행위 자체가 자금의 최종 목적지를 확정한다.
  포워더는 실제로 쓰이는 시점에 executor가 생성한다.

예측값은 로컬에서 다시 계산하지 않고 **살아 있는 팩토리**(`getForwarderAddress`)에서 읽는다. 팩토리의
`beaconInitCodeHash`는 initialize 시점에 스토리지에 고정되는데, 컴파일된 바이트코드로 로컬 재계산을 하면 그
값과 어긋날 수 있기 때문이다. 아울러 `TransitExecutor.factory()`가 예측에 사용한 그 팩토리인지도 확인한다.
어긋나 있으면 자금이 이미 소각된 뒤에 executor가 `RouteMismatch`로 메시지를 거부하게 된다.

## 준비

```bash
npm install
cp .env.example .env      # ROUTE_MINT_RECIPIENT(필수), 브로드캐스트하려면 NOBLE_PK를 채운다
```

`.env.example`은 현재 **메인넷**(Avalanche C-Chain + noble-1)의 배포된 executor/factory를 향한다. 테스트넷으로
돌리려면 `NOBLE_RPC`, `NOBLE_CHAIN_ID`, `EVM_RPC`, 두 컨트랙트 주소, 그리고 `IRIS_API`를 함께 바꾼다. 어테스테이션
서비스는 sandbox와 메인넷이 분리되어 있어서, 메인넷 burn을 sandbox로 조회하면 404가 난다.

## 사용법

세 커맨드 모두 **기본은 시뮬레이션**이며, 전송 플래그를 붙이기 전에는 아무것도 보내지 않는다.

```bash
# hop 1 — 빌드만: 확정된 라우트와 예측 포워더를 출력하고, 서명 안 된 tx.json을 쓴다
npm run burn -- --usdc 1.5
npm run burn -- --usdc 1.5 --from noble1...    # 키를 설정하지 않았을 때
npm run burn -- --usdc 1.5 --broadcast         # NOBLE_PK로 서명해서 전송

# hop 2 — burn이 출력한 Noble txhash를 넣는다
npm run execute -- --tx <nobleTxHash>                  # 어테스테이션 조회 + 시뮬레이션, 전송 안 함
npm run execute -- --tx <nobleTxHash> --wait 900 --send
npm run execute -- --tx <nobleTxHash> --refund --send  # 민팅 후 ROUTE_SENDER로 되돌린다

# hop 3 — execute가 출력한 Avalanche txhash를 넣는다
npm run mint -- --tx <avalancheTxHash>                 # 어테스테이션 조회 + 시뮬레이션, 전송 안 함
npm run mint -- --tx <avalancheTxHash> --wait 900 --send
```

`--amount`는 USDC 단위 대신 uusdc(소수점 6자리)를 받는다. `tx.json`은 `nobled tx sign` / `nobled tx broadcast`가
받아들이는 형태로 저장되므로, 이 도구가 한 번도 보지 않는 키로 burn에 서명할 수 있다. 각 커맨드에 `--help`를
붙이면 전체 옵션이 나온다.

### `execute`가 가스를 쓰기 전에 확인하는 것

Circle은 burn이 파이널라이즈된 뒤에야 어테스테이션을 발급한다. `--wait <초>`는 어테스테이션이 나타날 때까지
폴링하며, 없으면 한 번만 시도한다. 기다린다고 burn이 사라지지는 않으니 `execute --tx <hash>`는 언제든 다시
실행하면 된다.

호출을 만들기 전에 메시지를 파싱해서(`src/cctpMessage.ts`, 온체인 `CCTPV1Message` 라이브러리의 거울) 설정과
대조한다. 버전, 출발·도착 도메인, 예측된 포워더로 민팅되는지, executor가 `destinationCaller`로 고정되어
있는지, 수수료가 민팅되는 금액 안에 들어가는지. 이 전부는 온체인에서도 강제되며, 여기서 하는 일은 이미
가스를 쓴 뒤의 불투명한 revert를 읽을 수 있는 에러로 바꾸는 것뿐이다. executor의 `operator()`를 읽어
`EVM_PK`와 비교하는 것도 같은 이유다. `NotOperator`는 가장 흔하면서 가장 싸게 잡을 수 있는 실패다.

금액이 onward 수수료를 감당하지 못하면 `--refund`가 대신 `executeRefund`를 부른다. 두 번째 hop 없이 민팅해서
전부 `ROUTE_SENDER`로 돌려보내며, 수수료 관련 파라미터는 하나도 필요 없다.

## hop 3: Injective에서의 민팅

Injective의 EVM은 Circle의 표준 CCTP v2 컨트랙트를 그대로 돌린다. `MessageTransmitterV2`가 여느 체인과 같은
주소에 있고 `localDomain()`이 29를 리턴한다. 그래서 마지막 구간에는 우리 컨트랙트가 전혀 개입하지 않는다.
`mint`는 포워더가 내보낸 메시지의 어테스테이션을 받아 `receiveMessage`를 부르고, USDC는 포워더가 이미
확정해둔 `mintRecipient`로 민팅된다.

**어테스테이션은 hop 1–2와 다른 API에서 온다.** 민팅 구간은 CCTP v1이라 `burn`/`execute`는
`GET /v1/messages/4/{txHash}`를 읽는다. onward 구간은 CCTP v2이고 별도 인덱스에 있다:
`GET /v2/messages/1?transactionHash={txHash}`. 둘은 겹치지 않으며 각자 갖고 있지 않은 것에 대해서는 모두 404를
돌려준다. 그래서 Avalanche 해시를 v1로 조회하면 "pending"이 아니라 "Transaction hash not found"가 나온다.
`mint`는 v2 엔드포인트를 알아서 고르고, 못 찾으면 조용히 폴링하는 대신 어떤 좌표가 맞아떨어져야 하는지
알려준다.

이 hop에는 선택의 여지가 없다. `mintRecipient`, `amount`, `destinationCaller`는 Avalanche에서 메시지에 각인된
값이고 사후에 방향을 바꿀 수 없다. 따라서 `mint`가 하는 모든 검사는 메시지가 이미 말하고 있는 내용과의
대조다.

- `destinationCaller`가 이 커맨드가 무언가를 할 수 있는지 자체를 결정한다. **Injective에서** 키를 보유한
  계정이어야 한다. Avalanche 컨트랙트(포워더, executor)를 지정하면 아무도 제출할 수 없는 메시지가 만들어진다.
  자금은 Avalanche에서 소각되었고 Injective에서는 민팅 불가능한 상태가 되며, 회수 경로는 없다.
- `mintRecipient`는 `ROUTE_MINT_RECIPIENT`와 대조하며 불일치는 치명적 오류로 처리한다. 트랜스미터 자신은
  수취인이 누구인지 신경 쓰지 않는다. 값이 어긋난 메시지도 성공적으로, 남에게, 영구히 민팅된다.
- `usedNonces`를 먼저 읽으므로, 재실행 시 가스를 쓰고 revert하는 대신 "이미 민팅됨"이라고 보고한다.

서명 키는 `INJECTIVE_PK`이며 없으면 `EVM_PK`로 폴백한다. 운영자가 하나뿐인 배포에서는 그 오퍼레이터가 보통
고정된 caller이기도 해서, 같은 키를 변수 두 개에 복사해두는 것은 아무 이득이 없다.

## 구성

| 파일 | 역할 |
| --- | --- |
| `src/index.ts` | 커맨드 디스패치 (`burn` / `execute` / `mint`) |
| `src/config.ts` | 환경변수 해석과 검증. 배포된 테스트넷 기본값을 갖고 있다 |
| `src/burn.ts` | hop 1: Noble 메시지 조립, `tx.json` 쓰기, 선택적으로 서명·브로드캐스트 |
| `src/execute.ts` | hop 2: 메시지 프리플라이트 후 `executeTransit` / `executeRefund` 호출 |
| `src/mint.ts` | hop 3: onward 메시지 프리플라이트 후 Injective에서 `receiveMessage` 호출 |
| `src/predict.ts` | 살아 있는 팩토리에서 포워더 주소를 읽고, executor의 팩토리와 교차 확인 |
| `src/attestation.ts` | Circle Iris API 폴링 — 민팅 구간은 v1, onward 구간은 v2 |
| `src/cctpMessage.ts` | 온체인 CCTP v1 메시지 오프셋의 읽기 전용 거울 |
| `src/cctpV2Message.ts` | CCTP v2용 같은 것 — v1의 확장이 아니라 완전히 다른 레이아웃 |
| `src/proto.ts` | `circle.cctp.v1.MsgDepositForBurnWithCaller` 직접 구현 코덱 (`cosmjs-types`에 없음) |
