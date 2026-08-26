# noble-transit-burn

transit 경로를 처음부터 끝까지 실행해보는 도구.

| 커맨드 | 구간 | 하는 일 |
| --- | --- | --- |
| `check` | — | 설정된 배포를 온체인에서 읽어 배선이 맞는지 보고. 아무것도 보내지 않는다 |
| `burn` | Noble → 경유 체인 | CCTP v1 `depositForBurnWithCaller`를 만들고, 원하면 브로드캐스트 |
| `execute` | 경유 체인 → Injective | Circle 어테스테이션을 받아 `TransitExecutor.executeTransit` 호출 |
| `mint` | Injective 도착 | onward 어테스테이션을 받아 `MessageTransmitterV2.receiveMessage` 호출 |

CCTP hop 자체는 두 번이다(Noble→경유 체인이 v1, 경유 체인→Injective가 v2). 실행 커맨드가 셋인 이유는 두 번째
hop의 수신 쪽, 즉 Injective에서의 민팅이 별도 트랜잭션이기 때문이다.

## 경유 체인 고르기

경유 체인은 **Avalanche 또는 Polygon**이고(테스트넷은 Fuji / Amoy), 넷 다 서로 독립된 배포다. `.env`에서
고르는 값은 두 개뿐이며 나머지 체인 관련 설정은 전부 여기서 유도된다 — CCTP 도메인, RPC, executor/factory
주소, 어테스테이션 서비스, Noble 네트워크까지.

```
TRANSIT_CHAIN=polygon    # avalanche | polygon | fuji | amoy
DEPLOY_ENV=prod          # prod | dev  (테스트넷은 dev 하나뿐)
```

| | CCTP 도메인 | PROD executor / factory | DEV executor / factory |
| --- | --- | --- | --- |
| Avalanche (43114) | 1 | `0xF9701898…` / `0x62FbB274…` | `0x543f2c0d…` / `0x50Ca49b9…` |
| Polygon (137) | 7 | `0xF9701898…` / `0x62FbB274…` | `0x98C3cB71…` / `0xbda40fDB…` |
| Fuji (43113) | 1 | — | `0xb47F6534…` / `0x0EE32556…` |
| Amoy (80002) | 7 | — | `0x15238573…` / `0xe855c134…` |

⚠️ **PROD 주소는 두 메인넷에서 동일하다**(같은 deployer/nonce). 주소만으로는 어느 체인인지 알 수 없고,
`TRANSIT_CHAIN`만 바꾸고 `EVM_RPC`를 안 바꾼 `.env`는 살아 있는·정상 배선된 컨트랙트를 — 엉뚱한 체인에서 —
가리킨다. 그래서 모든 커맨드는 호출을 만들기 전에 체인 ID와 executor의 트랜스미터가 보고하는 CCTP 도메인을
읽어 대조한다. 어긋나면 그 자리에서 멈춘다.

`TRANSIT_EXECUTOR` / `TRANSIT_FACTORY`를 직접 주면 위 표보다 우선한다. 둘 다 주거나 둘 다 비워야 한다.

## 실행할 때 값 넘기기

`.env`에 있는 값은 전부 커맨드 플래그로 덮어쓸 수 있다. 우선순위는 **플래그 > `.env` > 내장 기본값**이며
네 커맨드 모두 동일하다. 주소·라우트처럼 실행마다 달라지는 값은 `.env`를 고치는 대신 플래그로 넘기는 쪽이
안전하다 — 무엇을 썼는지가 커맨드 자체와 셸 히스토리에 남는다.

| 플래그 | 대응 `.env` | |
| --- | --- | --- |
| `--chain <name>` | `TRANSIT_CHAIN` | avalanche \| polygon \| fuji \| amoy |
| `--env <prod\|dev>` | `DEPLOY_ENV` | 그 체인의 어느 배포인지 |
| `--recipient <addr>` | `ROUTE_MINT_RECIPIENT` | Injective의 최종 수취인 |
| `--route-sender <addr>` | `ROUTE_SENDER` | 라우트 키이자 환불 수취인 |
| `--route-domain <n>` | `ROUTE_DOMAIN` | 29 = Injective |
| `--onward-caller <addr>` | `ONWARD_DESTINATION_CALLER` | Injective에서 민팅할 수 있는 주소 |
| `--max-fee <uusdc>` | `MAX_FEE` | Circle의 도착측 상한 |
| `--finality <1000\|2000>` | `MIN_FINALITY_THRESHOLD` | |
| `--rpc` `--executor` `--factory` | 같은 이름의 변수 | |
| `--noble-rpc` `--injective-rpc` `--iris` | 같은 이름의 변수 | |

**32바이트가 필요한 자리에는 평범한 20바이트 주소를 그대로 넣어도 된다.** CCTP가 EVM 수취인을 인코딩하는
방식대로 왼쪽을 0으로 채워준다. 손으로 패딩하다 반대쪽을 채우면 조용히 남의 계정을 가리키게 되는데, 그
단계를 없애는 것이다. 이미 32바이트면 그대로 쓴다(비-EVM 목적지는 32바이트를 다 쓴다).

⚠️ `.env`에 `EVM_RPC`를 박아두면 `--chain`을 이긴다. 체인만 바꿔 가며 쓸 거라면 `EVM_RPC`는 비워두는 편이
좋다 — 비어 있으면 체인별 기본 RPC를 쓴다. 어긋난 경우는 첫 RPC 호출에서 체인 ID로 잡힌다.

```bash
# .env는 손대지 않고 Polygon PROD로 한 번만 돌려보기
npm run check -- --chain polygon --env prod --recipient 0x455AAA…
```

## 트랜잭션이 담아야 하는 것

```
Noble (domain 4)          경유 체인 (Avalanche 1 / Polygon 7)          Injective (domain 29)
  depositForBurnWithCaller  ──►  TransitExecutor.executeTransit   ──►   최종 수취인
    mintRecipient     = 예측된 TransitForwarder                          (ROUTE_MINT_RECIPIENT)
    destinationCaller = TransitExecutor
```

설계 전체를 지탱하는 필드는 두 개다.

- **`destinationCaller` = TransitExecutor** (PROD `0xF9701898e7a543028d47A3913BC191CaE7371334`). 이 메시지에 대해
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
npm run check             # 아무것도 보내지 않고 배선만 확인
```

`.env.example`은 **Polygon PROD**를 가리킨다. 다른 체인으로 돌리려면 `TRANSIT_CHAIN` 한 줄만 바꾸면 된다.
테스트넷(`fuji` / `amoy`)을 고르면 Noble도 `grand-1`로, 어테스테이션도 sandbox로 함께 따라간다 — 이 둘은 각각
메인넷과 분리된 인덱스라서, 테스트넷 burn을 메인넷 Iris로 조회하면 영원히 404다. `INJECTIVE_RPC`만은 따라가지
않으니 테스트넷에서는 직접 지정해야 한다.

### 예전 `.env`에서 넘어올 때

| 예전 | 지금 |
| --- | --- |
| `AVALANCHE_DOMAIN` | `TRANSIT_CHAIN`에서 유도. 굳이 덮어쓰려면 `TRANSIT_DOMAIN` |
| `FEE_AMOUNT` | **삭제됨.** v2 포워더는 릴레이어 수수료를 떼지 않는다 |
| `TRANSIT_EXECUTOR` / `TRANSIT_FACTORY` | 선택. 안 주면 `TRANSIT_CHAIN` + `DEPLOY_ENV`가 고른다 |
| `EVM_RPC` / `IRIS_API` / `NOBLE_RPC` / `NOBLE_CHAIN_ID` | 선택. 체인에서 유도 |

앞의 두 개는 조용히 무시하지 않고 **에러를 낸다**. 무시하면 설정한 사람에게는 "여전히 Avalanche를 향하고
있다"거나 "수수료를 떼고 있다"는 확인처럼 읽히기 때문이다.

## 사용법

실행 커맨드 셋은 모두 **기본이 시뮬레이션**이며, 전송 플래그를 붙이기 전에는 아무것도 보내지 않는다.

```bash
# hop 0 — 어디를 향하고 있는지 확인 (키도 필요 없다)
npm run check
npm run check -- --chain avalanche --env prod --recipient 0x<injective 주소>

# hop 1 — 빌드만: 확정된 라우트와 예측 포워더를 출력하고, 서명 안 된 tx.json을 쓴다
npm run burn -- --usdc 1.5
npm run burn -- --usdc 1.5 --from noble1...    # 키를 설정하지 않았을 때
npm run burn -- --usdc 1.5 --broadcast         # NOBLE_PK로 서명해서 전송

# hop 2 — burn이 출력한 Noble txhash를 넣는다
npm run execute -- --tx <nobleTxHash>                  # 어테스테이션 조회 + 시뮬레이션, 전송 안 함
npm run execute -- --tx <nobleTxHash> --wait 900 --send
npm run execute -- --tx <nobleTxHash> --refund --send  # 민팅 후 ROUTE_SENDER로 되돌린다

# hop 3 — execute가 출력한 경유 체인 txhash를 넣는다
npm run mint -- --tx <transitTxHash>                   # 어테스테이션 조회 + 시뮬레이션, 전송 안 함
npm run mint -- --tx <transitTxHash> --wait 900 --send
```

`--amount`는 USDC 단위 대신 uusdc(소수점 6자리)를 받는다. `tx.json`은 `nobled tx sign` / `nobled tx broadcast`가
받아들이는 형태로 저장되므로, 이 도구가 한 번도 보지 않는 키로 burn에 서명할 수 있다. 각 커맨드에 `--help`를
붙이면 전체 옵션이 나온다.

### `execute`가 가스를 쓰기 전에 확인하는 것

Circle은 burn이 파이널라이즈된 뒤에야 어테스테이션을 발급한다. `--wait <초>`는 어테스테이션이 나타날 때까지
폴링하며, 없으면 한 번만 시도한다. 기다린다고 burn이 사라지지는 않으니 `execute --tx <hash>`는 언제든 다시
실행하면 된다.

먼저 배포 자체를 확인한다(`src/deployment.ts`). 체인 ID가 `TRANSIT_CHAIN`과 맞는지, executor가 이 도구가
호출을 만드는 버전(v2)인지, executor가 쓰는 팩토리가 `TRANSIT_FACTORY`인지, executor의 트랜스미터가 보고하는
CCTP 도메인이 설정된 경유 도메인과 같은지, 그 트랜스미터가 v1인지. 버전 검사는 이론적인 게 아니다 — 폐기된
v1 배포의 `executeTransit`은 지금은 없어진 `feeAmount` 인자를 아직 받고 있어서, 현재 소스로 만든 호출은
디코딩조차 되지 않고 revert 메시지도 아무것도 말해주지 않는다.

그 다음 메시지를 파싱해서(`src/cctpMessage.ts`, 온체인 `CCTPV1Message` 라이브러리의 거울) 설정과 대조한다.
버전, 출발·도착 도메인, 예측된 포워더로 민팅되는지, executor가 `destinationCaller`로 고정되어 있는지,
`MAX_FEE`가 민팅되는 금액보다 작은지. 이 전부는 온체인에서도 강제되며, 여기서 하는 일은 이미 가스를 쓴 뒤의
불투명한 revert를 읽을 수 있는 에러로 바꾸는 것뿐이다. executor의 `operator()`를 읽어 `EVM_PK`와 비교하는
것도 같은 이유다. `NotOperator`는 가장 흔하면서 가장 싸게 잡을 수 있는 실패다.

민팅된 금액은 **전액** 다음 hop으로 나간다. 라우트가 떼는 수수료는 없다 — v2 포워더는 Circle의
TokenMessenger를 직접 부르고, `MAX_FEE`는 우리 몫이 아니라 Circle이 도착 측에서 떼는 상한이다. onward burn이
불가능한 메시지는 `--refund`가 `executeRefund`를 대신 불러서, 두 번째 hop 없이 민팅만 하고 전부
`ROUTE_SENDER`로 돌려보낸다.

## hop 3: Injective에서의 민팅

Injective의 EVM은 Circle의 표준 CCTP v2 컨트랙트를 그대로 돌린다. `MessageTransmitterV2`가 여느 체인과 같은
주소에 있고 `localDomain()`이 29를 리턴한다. 그래서 마지막 구간에는 우리 컨트랙트가 전혀 개입하지 않는다.
`mint`는 포워더가 내보낸 메시지의 어테스테이션을 받아 `receiveMessage`를 부르고, USDC는 포워더가 이미
확정해둔 `mintRecipient`로 민팅된다.

**어테스테이션은 hop 1–2와 다른 API에서 온다.** 민팅 구간은 CCTP v1이라 `burn`/`execute`는
`GET /v1/messages/4/{txHash}`를 읽는다. onward 구간은 CCTP v2이고 별도 인덱스에 있다:
`GET /v2/messages/{경유 도메인}?transactionHash={txHash}` (Avalanche면 1, Polygon이면 7). 둘은 겹치지 않으며
각자 갖고 있지 않은 것에 대해서는 모두 404를 돌려준다. 그래서 경유 체인 해시를 v1로 조회하면 "pending"이
아니라 "Transaction hash not found"가 나온다.
`mint`는 v2 엔드포인트를 알아서 고르고, 못 찾으면 조용히 폴링하는 대신 어떤 좌표가 맞아떨어져야 하는지
알려준다.

이 hop에는 선택의 여지가 없다. `mintRecipient`, `amount`, `destinationCaller`는 경유 체인에서 메시지에 각인된
값이고 사후에 방향을 바꿀 수 없다. 따라서 `mint`가 하는 모든 검사는 메시지가 이미 말하고 있는 내용과의
대조다.

- `destinationCaller`가 이 커맨드가 무언가를 할 수 있는지 자체를 결정한다. **Injective에서** 키를 보유한
  계정이어야 한다. 경유 체인의 컨트랙트(포워더, executor)를 지정하면 아무도 제출할 수 없는 메시지가
  만들어진다. 자금은 경유 체인에서 소각되었고 Injective에서는 민팅 불가능한 상태가 되며, 회수 경로는 없다.
- `mintRecipient`는 `ROUTE_MINT_RECIPIENT`와 대조하며 불일치는 치명적 오류로 처리한다. 트랜스미터 자신은
  수취인이 누구인지 신경 쓰지 않는다. 값이 어긋난 메시지도 성공적으로, 남에게, 영구히 민팅된다.
- `usedNonces`를 먼저 읽으므로, 재실행 시 가스를 쓰고 revert하는 대신 "이미 민팅됨"이라고 보고한다.

서명 키는 `INJECTIVE_PK`이며 없으면 `EVM_PK`로 폴백한다. 운영자가 하나뿐인 배포에서는 그 오퍼레이터가 보통
고정된 caller이기도 해서, 같은 키를 변수 두 개에 복사해두는 것은 아무 이득이 없다.

## 구성

| 파일 | 역할 |
| --- | --- |
| `src/index.ts` | 커맨드 디스패치 (`check` / `burn` / `execute` / `mint`) |
| `src/config.ts` | 환경변수 해석과 검증. 체인 선택에서 나머지를 유도한다 |
| `src/chains.ts` | 지원 경유 체인과 배포 주소 레지스트리 (`script/Config.sol`의 거울) |
| `src/deployment.ts` | 살아 있는 executor를 읽고 체인·버전·배선을 설정과 대조 |
| `src/check.ts` | `check` 커맨드: 위 전부를 읽어서 보고만 한다 |
| `src/burn.ts` | hop 1: Noble 메시지 조립, `tx.json` 쓰기, 선택적으로 서명·브로드캐스트 |
| `src/execute.ts` | hop 2: 메시지 프리플라이트 후 `executeTransit` / `executeRefund` 호출 |
| `src/mint.ts` | hop 3: onward 메시지 프리플라이트 후 Injective에서 `receiveMessage` 호출 |
| `src/predict.ts` | 살아 있는 팩토리에서 포워더 주소를 읽고, executor의 팩토리와 교차 확인 |
| `src/attestation.ts` | Circle Iris API 폴링 — 민팅 구간은 v1, onward 구간은 v2 |
| `src/cctpMessage.ts` | 온체인 CCTP v1 메시지 오프셋의 읽기 전용 거울 |
| `src/cctpV2Message.ts` | CCTP v2용 같은 것 — v1의 확장이 아니라 완전히 다른 레이아웃 |
| `src/proto.ts` | `circle.cctp.v1.MsgDepositForBurnWithCaller` 직접 구현 코덱 (`cosmjs-types`에 없음) |
