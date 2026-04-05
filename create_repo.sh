#!/usr/bin/env bash
set -euo pipefail

ROOT="arena-web3-game-platform"
ZIPNAME="${ROOT}.zip"

if [ -d "$ROOT" ]; then
  echo "Directory $ROOT already exists. Remove it first or choose another location."
  exit 1
fi

mkdir -p "$ROOT"
cd "$ROOT"

echo "Creating workspace files..."

cat > package.json <<'EOF'
{
  "name": "arena-web3-game-platform",
  "private": true,
  "version": "0.1.0",
  "workspaces": [
    "contracts",
    "backend",
    "frontend",
    "admin",
    "shared"
  ],
  "scripts": {
    "install:all": "pnpm -w install",
    "build:all": "pnpm -w -r run build",
    "start:backend": "pnpm --filter backend start",
    "dev:backend": "pnpm --filter backend dev",
    "dev:frontend": "pnpm --filter frontend dev",
    "dev:admin": "pnpm --filter admin dev",
    "test": "echo \"Run tests per package\""
  }
}
EOF

cat > pnpm-workspace.yaml <<'EOF'
packages:
  - 'contracts'
  - 'backend'
  - 'frontend'
  - 'admin'
  - 'shared'
EOF

cat > .gitignore <<'EOF'
/node_modules
/.env
/dist
/.cache
/.next
/hardhat-deploy
/hardhat-artifacts
/out
/coverage
EOF

cat > .env.example <<'EOF'
# Backend
DATABASE_URL="postgresql://USER:PASSWORD@localhost:5432/arena?schema=public"
JWT_SECRET="change-me-to-a-strong-secret"
BACKEND_ADMIN_ADDRESSES="0xYourAdminWallet"
BACKEND_PRIVATE_KEY="0xYOUR_BACKEND_WALLET_PRIVATE_KEY"
INFURA_API_KEY="your-infura-or-alchemy-key"
NETWORK="sepolia"
GAME_REWARD_CONTRACT_ADDRESS=""
ARNA_TOKEN_ADDRESS="0x3b855F88CB93aA642EaEB13F59987C552Fc614b5"
TREASURY_ADDRESS="0xYourTreasuryAddress"
REDIS_URL="redis://localhost:6379"

# Deployed contracts (example addresses you provided)
MARKETPLACE_CONTRACT_ADDRESS="0x67817157Dd6E5945ac2fAf1a822e7f1dE26C698E"
CHAMPION_CONTRACT_ADDRESS="0x68f08b005b09B0F7D07E1c0B5CDe18E43CE2486A"
ARENA_BATTLE_CONTRACT_ADDRESS="0xF6fc2B6a306B626548ca9dF25B31a22D0f8971CF"
ARENA_PVP_CONTRACT_ADDRESS="0xd0C4Af12E95f9590e7314D079C58597771E57533"

# Hardhat / deploy
MNEMONIC=""
DEPLOYER_PRIVATE_KEY="0xYOUR_DEPLOY_PRIVATE_KEY"
ETHERSCAN_API_KEY=""

# Frontend / Admin
NEXT_PUBLIC_API_URL="http://localhost:4000"
NEXT_PUBLIC_CHAIN_NAME="sepolia"
EOF

cat > README.md <<'EOF'
# Arena Web3 Game Platform (monorepo)

This repository contains a production-oriented Web3 gaming platform with:
- Next.js frontend (game)
- Next.js admin dashboard
- Node.js + Express backend with Socket.IO
- Solidity smart contracts (Hardhat): ArenaToken (ARNA) and GameReward
- PostgreSQL via Prisma
- Secure wallet-based authentication (signature-based)
- Server-side RNG and validated server game logic
- On-chain rewards minted and distributed only by backend wallet

Quick local dev steps (development mode)
1. Install dependencies:
   - pnpm install (or npm/yarn, but this repo uses pnpm workspaces)
2. Set up Postgres database and fill DATABASE_URL in `backend/.env`
3. Setup .env values (copy `.env.example` to `.env` in backend and admin)
4. From backend package:
   - pnpm --filter backend prisma:generate
   - pnpm --filter backend prisma:migrate dev --name init
5. Deploy contracts (local hardhat or testnet):
   - cd contracts
   - pnpm hardhat deploy --network sepolia (requires DEPLOYER_PRIVATE_KEY and INFURA)
   - Save deployed addresses to .env: GAME_REWARD_CONTRACT_ADDRESS, ARNA_TOKEN_ADDRESS
6. Run backend:
   - pnpm --filter backend dev
7. Run frontend:
   - pnpm --filter frontend dev
8. Run admin:
   - pnpm --filter admin dev

Security notes:
- All game-critical logic (spins, battle resolution) occurs server-side.
- Backend wallet keys must never be committed; use environment variables and secrets manager.
- Admin routes require JWT from a wallet address marked as admin in BACKEND_ADMIN_ADDRESSES.

Deployment targets:
- Frontend: Vercel
- Backend: Railway/Render (use env variables)
- Contracts: deploy to Sepolia or Base as chosen

EOF

echo "Creating contracts package..."
mkdir -p contracts/contracts contracts/scripts contracts/abis

cat > contracts/contracts/ArenaToken.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ArenaToken is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("ArenaToken", "ARNA") {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
EOF

cat > contracts/contracts/GameReward.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./ArenaToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/*
 GameReward controls distribution of ArenaToken rewards.
 - Only owner (backend deployer) can call reward()
 - Has finite rewardPool that decreases on reward calls
 - On reward, a small burn% is applied and treasury receives treasury%
 - Emits Rewarded event for every distribution
*/
contract GameReward is Ownable {
    ArenaToken public token;
    address public treasury;
    uint256 public rewardPool; // in token smallest units
    uint256 public burnBps; // basis points (2-5% => 200 - 500)
    uint256 public treasuryBps; // basis points for treasury

    event Rewarded(address indexed to, uint256 grossAmount, uint256 netAmount, uint256 burned, uint256 treasuryShare);

    constructor(address tokenAddress, address treasuryAddress, uint256 initialPool, uint256 _burnBps, uint256 _treasuryBps) {
        token = ArenaToken(tokenAddress);
        treasury = treasuryAddress;
        rewardPool = initialPool;
        burnBps = _burnBps;
        treasuryBps = _treasuryBps;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function topUpPool(uint256 amount) external onlyOwner {
        // owner mints to this contract then increases pool
        rewardPool += amount;
    }

    function reducePool(uint256 amount) internal {
        require(rewardPool >= amount, "insufficient reward pool");
        rewardPool -= amount;
    }

    // reward: only owner (backend) calls this
    function reward(address to, uint256 grossAmount) external onlyOwner {
        require(grossAmount > 0, "zero reward");
        // enforce pool
        reducePool(grossAmount);

        // mint gross to this contract, then distribute
        token.mint(address(this), grossAmount);

        uint256 burned = (grossAmount * burnBps) / 10000;
        uint256 treasuryShare = (grossAmount * treasuryBps) / 10000;
        uint256 net = grossAmount - burned - treasuryShare;

        if (burned > 0) {
            token.burn(burned);
        }

        if (treasuryShare > 0) {
            token.transfer(treasury, treasuryShare);
        }

        if (net > 0) {
            token.transfer(to, net);
        }

        emit Rewarded(to, grossAmount, net, burned, treasuryShare);
    }
}
EOF

cat > contracts/hardhat.config.ts <<'EOF'
import { HardhatUserConfig } from "hardhat/types";
import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";
import * as dotenv from "dotenv";
dotenv.config();

const config: HardhatUserConfig = {
  solidity: "0.8.25",
  networks: {
    sepolia: {
      url: process.env.INFURA_API_KEY ? `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}` : process.env.RPC_URL,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : []
    }
  },
  namedAccounts: {
    deployer: 0
  }
};

export default config;
EOF

cat > contracts/scripts/deploy.ts <<'EOF'
import { ethers, deployments, getNamedAccounts } from "hardhat";

async function main() {
  const { deployer } = await getNamedAccounts();
  console.log("Deployer:", deployer);

  const initialPool = ethers.utils.parseUnits("1000000", 18); // 1M tokens
  const burnBps = 300; // 3%
  const treasuryBps = 200; // 2%

  const arenaToken = await deployments.deploy("ArenaToken", {
    from: deployer,
    args: [],
    log: true
  });

  const gameReward = await deployments.deploy("GameReward", {
    from: deployer,
    args: [arenaToken.address, deployer /* set treasury same for now; update later */, initialPool, burnBps, treasuryBps],
    log: true
  });

  console.log("ArenaToken deployed:", arenaToken.address);
  console.log("GameReward deployed:", gameReward.address);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
EOF

cat > contracts/abis/Marketplace.json <<'EOF'
[{"inputs":[{"internalType":"address","name":"_champions","type":"address"},{"internalType":"address","name":"_arenaToken","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"arenaToken","outputs":[{"internalType":"contract IArenaCoin","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"listingId","type":"uint256"}],"name":"buyNFT","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"champions","outputs":[{"internalType":"contract IArenaChampion","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"tokenId","type":"uint256"},{"internalType":"uint256","name":"price","type":"uint256"}],"name":"listNFT","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"listingCounter","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"listings","outputs":[{"internalType":"address","name":"seller","type":"address"},{"internalType":"uint256","name":"tokenId","type":"uint256"},{"internalType":"uint256","name":"price","type":"uint256"},{"internalType":"bool","name":"active","type":"bool"}],"stateMutability":"view","type":"function"}]
EOF

cat > contracts/abis/ChallengeManager.json <<'EOF'
[{"inputs":[{"internalType":"address","name":"_champions","type":"address"},{"internalType":"address","name":"_arenaToken","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"uint256","name":"challengeId","type":"uint256"},{"indexed":true,"internalType":"address","name":"winner","type":"address"},{"indexed":true,"internalType":"address","name":"loser","type":"address"},{"indexed":false,"internalType":"uint256","name":"prize","type":"uint256"}],"name":"BattleResolved","type":"event"},{"inputs":[{"internalType":"uint256","name":"challengeId","type":"uint256"},{"internalType":"uint256","name":"myChampionId","type":"uint256"}],"name":"acceptChallenge","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"arenaToken","outputs":[{"internalType":"contract IArenaCoin","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"challengeCounter","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"challenges","outputs":[{"internalType":"address","name":"challenger","type":"address"},{"internalType":"uint256","name":"challengerChampionId","type":"uint256"},{"internalType":"bool","name":"active","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"champions","outputs":[{"internalType":"contract IArenaChampion","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"championId","type":"uint256"}],"name":"createChallenge","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"wagerAmount","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]
EOF

cat > contracts/abis/Tournament.json <<'EOF'
[{"inputs":[{"internalType":"address","name":"_arenaToken","type":"address"},{"internalType":"address","name":"_champions","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"player","type":"address"},{"indexed":false,"internalType":"uint256","name":"reward","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"nftId","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"attack","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"defense","type":"uint256"},{"indexed":false,"internalType":"uint8","name":"rarity","type":"uint8"}],"name":"BattleResult","type":"event"},{"inputs":[],"name":"arenaToken","outputs":[{"internalType":"contract IArenaCoin","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"champions","outputs":[{"internalType":"contract IArenaChampion","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"enterBattle","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"entryFee","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]
EOF

cat > contracts/abis/Champion.json <<'EOF'
[{"inputs":[{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"tokenId","type":"uint256"}],"name":"approve","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"champions","outputs":[{"internalType":"uint256","name":"attack","type":"uint256"},{"internalType":"uint256","name":"defense","type":"uint256"},{"internalType":"uint8","name":"rarity","type":"uint8"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"tokenId","type":"uint256"}],"name":"getChampion","outputs":[{"components":[{"internalType":"uint256","name":"attack","type":"uint256"},{"internalType":"uint256","name":"defense","type":"uint256"},{"internalType":"uint8","name":"rarity","type":"uint8"}],"internalType":"struct Champion","name":"","type":"tuple"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"attack","type":"uint256"},{"internalType":"uint256","name":"defense","type":"uint256"},{"internalType":"uint8","name":"rarity","type":"uint8"}],"name":"mintChampion","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"name","outputs":[{"internalType":"string","name":"","type":"string"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"nextTokenId","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"tokenId","type":"uint256"}],"name":"ownerOf","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"symbol","outputs":[{"internalType":"string","name":"","type":"string"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"},{"internalType":"uint256","name":"index","type":"uint256"}],"name":"tokenOfOwnerByIndex","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"from","type":"address"},{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"tokenId","type":"uint256"}],"name":"transferFrom","outputs":[],"stateMutability":"nonpayable","type":"function"}]
EOF

cat > contracts/abis/ERC20.json <<'EOF'
[{"inputs":[],"stateMutability":"nonpayable","type":"constructor"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"owner","type":"address"},{"indexed":true,"internalType":"address","name":"spender","type":"address"},{"indexed":false,"internalType":"uint256","name":"value","type":"uint256"}],"name":"Approval","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"from","type":"address"},{"indexed":true,"internalType":"address","name":"to","type":"address"},{"indexed":false,"internalType":"uint256","name":"value","type":"uint256"}],"name":"Transfer","type":"event"},{"inputs":[{"internalType":"address","name":"owner","type":"address"},{"internalType":"address","name":"spender","type":"address"}],"name":"allowance","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"approve","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"decimals","outputs":[{"internalType":"uint8","name":"","type":"uint8"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"subtractedValue","type":"uint256"}],"name":"decreaseAllowance","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"addedValue","type":"uint256"}],"name":"increaseAllowance","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"name","outputs":[{"internalType":"string","name":"","type":"string"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"symbol","outputs":[{"internalType":"string","name":"","type":"string"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"totalSupply","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"transfer","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"from","type":"address"},{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"transferFrom","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"}]
EOF

echo "Creating backend package..."
mkdir -p backend/src backend/prisma backend/src/routes backend/src/services backend/src/middleware backend/src/workers

cat > backend/package.json <<'EOF'
{
  "name": "backend",
  "version": "0.1.0",
  "main": "dist/index.js",
  "license": "MIT",
  "scripts": {
    "dev": "ts-node-dev --respawn --transpile-only src/index.ts",
    "build": "tsc -p .",
    "start": "node dist/index.js",
    "prisma:generate": "prisma generate",
    "prisma:migrate": "prisma migrate dev --name init",
    "worker": "ts-node-dev --respawn --transpile-only src/workers/eventIndexer.ts"
  },
  "dependencies": {
    "@prisma/client": "^5.0.0",
    "axios": "^1.4.0",
    "cors": "^2.8.5",
    "crypto": "^1.0.1",
    "dotenv": "^16.0.0",
    "express": "^4.18.2",
    "express-rate-limit": "^6.7.0",
    "helmet": "^6.0.1",
    "http-status-codes": "^2.2.0",
    "jsonwebtoken": "^9.0.0",
    "prisma": "^5.0.0",
    "socket.io": "^4.7.2",
    "socket.io-client": "^4.7.2",
    "ethers": "^6.8.0"
  },
  "devDependencies": {
    "@types/express": "^4.17.17",
    "@types/jsonwebtoken": "^9.0.2",
    "ts-node-dev": "^2.0.0",
    "typescript": "^5.2.2"
  }
}
EOF

cat > backend/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "outDir": "dist",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
EOF

cat > backend/src/index.ts <<'EOF'
import express from "express";
import http from "http";
import { Server as SocketIOServer } from "socket.io";
import cors from "cors";
import helmet from "helmet";
import dotenv from "dotenv";
import { PrismaClient } from "@prisma/client";
import authRoutes from "./routes/auth";
import spinRoutes from "./routes/spin";
import battleRoutes from "./routes/battle";
import marketplaceRoutes from "./routes/marketplace";
import challengeRoutes from "./routes/challenges";
import adminRoutes from "./routes/admin";
import { attachSocketHandlers } from "./socket";
import { initContractListeners } from "./services/contractListeners";
import rateLimit from "express-rate-limit";

dotenv.config();

const app = express();
const server = http.createServer(app);
const io = new SocketIOServer(server, { cors: { origin: "*" } });

app.use(helmet());
app.use(cors({ origin: process.env.NEXT_PUBLIC_API_URL || "*" }));
app.use(express.json());

const prisma = new PrismaClient();

// global rate limiter for anonymous endpoints
const globalLimiter = rateLimit({
  windowMs: 10 * 1000,
  max: 100,
  keyGenerator: (req) => req.ip
});
app.use(globalLimiter);

// attach DI
app.set("prisma", prisma);
app.set("io", io);

app.use("/auth", authRoutes);
app.use("/spin", spinRoutes);
app.use("/battle", battleRoutes);
app.use("/marketplace", marketplaceRoutes);
app.use("/challenges", challengeRoutes);
app.use("/admin", adminRoutes);

// basic health
app.get("/health", (req, res) => res.json({ ok: true }));

// socket handlers for real-time gameplay
attachSocketHandlers(io, prisma);

// init contract listeners (best-effort)
initContractListeners(prisma);

const PORT = process.env.PORT ? Number(process.env.PORT) : 4000;
server.listen(PORT, () => {
  console.log(`Backend listening on ${PORT}`);
});
EOF

cat > backend/src/middleware/auth.ts <<'EOF'
import { Request, Response, NextFunction } from "express";
import jwt from "jsonwebtoken";
import dotenv from "dotenv";
dotenv.config();

export interface AuthRequest extends Request {
  auth?: {
    address: string;
    isAdmin?: boolean;
  };
}

export function authMiddleware(req: AuthRequest, res: Response, next: NextFunction) {
  const header = req.header("Authorization");
  if (!header) return res.status(401).json({ error: "missing auth" });
  const token = header.replace("Bearer ", "");
  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET || "") as any;
    req.auth = { address: payload.address, isAdmin: payload.isAdmin };
    next();
  } catch (e) {
    return res.status(401).json({ error: "invalid token" });
  }
}

export function adminOnly(req: AuthRequest, res: Response, next: NextFunction) {
  if (!req.auth) return res.status(401).json({ error: "missing auth" });
  if (!req.auth.isAdmin) return res.status(403).json({ error: "admin required" });
  next();
}
EOF

cat > backend/src/routes/auth.ts <<'EOF'
import express from "express";
import crypto from "crypto";
import { ethers } from "ethers";
import jwt from "jsonwebtoken";
import dotenv from "dotenv";
import { PrismaClient } from "@prisma/client";

dotenv.config();
const router = express.Router();

router.get("/nonce", async (req, res) => {
  const prisma: PrismaClient = (req.app.get("prisma") as PrismaClient);
  const address = (req.query.address as string)?.toLowerCase();
  if (!address) return res.status(400).json({ error: "address required" });
  const raw = crypto.randomBytes(16).toString("hex");
  const nonce = `Login to ArenaGame: ${raw}`;
  await prisma.nonce.upsert({
    where: { address },
    update: { nonce },
    create: { address, nonce }
  });
  res.json({ nonce });
});

router.post("/login", async (req, res) => {
  try {
    const prisma: PrismaClient = (req.app.get("prisma") as PrismaClient);
    const { address, signature } = req.body;
    if (!address || !signature) return res.status(400).json({ error: "address+signature required" });
    const addr = address.toLowerCase();
    const record = await prisma.nonce.findUnique({ where: { address: addr } });
    if (!record) return res.status(400).json({ error: "no nonce, request /auth/nonce first" });

    const recovered = ethers.verifyMessage(record.nonce, signature);
    if (recovered.toLowerCase() !== addr) return res.status(401).json({ error: "invalid signature" });

    let user = await prisma.user.findUnique({ where: { address: addr } });
    if (!user) {
      const cooldown = 3 + Math.floor(Math.random() * 8);
      user = await prisma.user.create({ data: { address: addr, nonce: crypto.randomBytes(8).toString("hex"), cooldownSecs: cooldown } });
    } else {
      await prisma.user.update({ where: { id: user.id }, data: { nonce: crypto.randomBytes(8).toString("hex") } });
    }

    await prisma.nonce.deleteMany({ where: { address: addr } });

    const isAdmin = (process.env.BACKEND_ADMIN_ADDRESSES || "").toLowerCase().split(",").includes(addr);
    const token = jwt.sign({ address: addr, isAdmin }, process.env.JWT_SECRET || "", { expiresIn: "7d" });
    res.json({ token, address: addr });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "internal" });
  }
});

export default router;
EOF

cat > backend/src/utils/rng.ts <<'EOF'
import crypto from "crypto";

/**
 * Choose reward tier using server-side secure RNG.
 * Probabilities:
 *  - common: 70%
 *  - rare: 25%
 *  - jackpot: 5%
 */
export function chooseSpinTier() {
  const r = crypto.randomInt(0, 10000); // 0..9999
  if (r < 7000) return "common";
  if (r < 7000 + 2500) return "rare";
  return "jackpot";
}
EOF

cat > backend/src/services/eth.ts <<'EOF'
import { ethers } from "ethers";
import dotenv from "dotenv";
dotenv.config();

let provider: ethers.Provider;
let signer: ethers.Wallet;
if (process.env.INFURA_API_KEY) {
  provider = new ethers.JsonRpcProvider(`https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`);
} else {
  provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
}
if (!process.env.BACKEND_PRIVATE_KEY) throw new Error("BACKEND_PRIVATE_KEY required");
signer = new ethers.Wallet(process.env.BACKEND_PRIVATE_KEY, provider);

export { provider, signer, ethers };
EOF

cat > backend/src/services/contractClients.ts <<'EOF'
import fs from "fs";
import path from "path";
import dotenv from "dotenv";
import { ethers } from "ethers";
import { provider, signer } from "./eth";
dotenv.config();

function loadAbi(filename: string) {
  const p = path.join(process.cwd(), "contracts", "abis", filename);
  const raw = fs.readFileSync(p, "utf8");
  return JSON.parse(raw);
}

export const ARNA_TOKEN_ADDRESS = process.env.ARNA_TOKEN_ADDRESS!;
export const MARKETPLACE_ADDRESS = process.env.MARKETPLACE_CONTRACT_ADDRESS!;
export const CHAMPION_ADDRESS = process.env.CHAMPION_CONTRACT_ADDRESS!;
export const ARENA_BATTLE_ADDRESS = process.env.ARENA_BATTLE_CONTRACT_ADDRESS!;
export const ARENA_PVP_ADDRESS = process.env.ARENA_PVP_CONTRACT_ADDRESS!;

export const arenaToken = new ethers.Contract(ARNA_TOKEN_ADDRESS, loadAbi("ERC20.json"), signer);
export const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, loadAbi("Marketplace.json"), signer);
export const champions = new ethers.Contract(CHAMPION_ADDRESS, loadAbi("Champion.json"), signer);
export const arenaBattle = new ethers.Contract(ARENA_BATTLE_ADDRESS, loadAbi("Tournament.json"), signer);
export const arenaPVP = new ethers.Contract(ARENA_PVP_ADDRESS, loadAbi("ChallengeManager.json"), signer);
EOF

cat > backend/src/services/contractListeners.ts <<'EOF'
import { PrismaClient } from "@prisma/client";
import { marketplace, champions, arenaBattle, arenaPVP, arenaToken } from "./contractClients";
import { ethers } from "ethers";

/**
 * Light-weight live listeners. For production reliability use the indexer worker.
 */
export function initContractListeners(prisma: PrismaClient) {
  try {
    arenaPVP.on("BattleResolved", async (challengeId: ethers.BigNumber, winner: string, loser: string, prize: ethers.BigNumber, event: any) => {
      console.log("BattleResolved", challengeId.toString(), winner, loser, prize.toString());
      try {
        await prisma.onChainEvent.create({
          data: {
            contract: "arenaPVP",
            eventName: "BattleResolved",
            blockNumber: Number(event.blockNumber),
            txHash: event.transactionHash,
            parsed: { challengeId: challengeId.toString(), winner, loser, prize: prize.toString() }
          }
        });
      } catch (e) {
        console.error("persist BattleResolved failed", e);
      }
    });
  } catch (e) {
    console.warn("arenaPVP listener attach failed:", e);
  }

  try {
    arenaBattle.on("BattleResult", async (player: string, reward: ethers.BigNumber, nftId: ethers.BigNumber, attack: ethers.BigNumber, defense: ethers.BigNumber, rarity: number, event: any) => {
      console.log("BattleResult", player, reward.toString(), nftId.toString());
      try {
        await prisma.onChainEvent.create({
          data: {
            contract: "arenaBattle",
            eventName: "BattleResult",
            blockNumber: Number(event.blockNumber),
            txHash: event.transactionHash,
            parsed: { player, reward: reward.toString(), nftId: nftId.toString(), attack: attack.toString(), defense: defense.toString(), rarity }
          }
        });
      } catch (err) {
        console.error("persist BattleResult failed", err);
      }
    });
  } catch (e) {
    console.warn("arenaBattle listener attach failed:", e);
  }

  try {
    arenaToken.on("Transfer", async (from: string, to: string, value: ethers.BigNumber, event: any) => {
      console.log("ARNA Transfer", from, to, value.toString());
      try {
        await prisma.onChainEvent.create({
          data: {
            contract: "arenaToken",
            eventName: "Transfer",
            blockNumber: Number(event.blockNumber),
            txHash: event.transactionHash,
            parsed: { from, to, value: value.toString() }
          }
        });
      } catch (err) {
        console.error("persist ARNA Transfer failed", err);
      }
    });
  } catch (e) {
    console.warn("arenaToken listener attach failed:", e);
  }

  try {
    champions.on("Transfer", async (from: string, to: string, tokenId: ethers.BigNumber, event: any) => {
      console.log("Champion Transfer", from, to, tokenId.toString());
      try {
        await prisma.onChainEvent.create({
          data: {
            contract: "champions",
            eventName: "Transfer",
            blockNumber: Number(event.blockNumber),
            txHash: event.transactionHash,
            parsed: { from, to, tokenId: tokenId.toString() }
          }
        });
      } catch (err) {
        console.error("persist Champion Transfer failed", err);
      }
    });
  } catch (e) {
    console.warn("champions listener attach failed:", e);
  }

  console.log("Live contract listeners attached (best-effort).");
}
EOF

cat > backend/src/workers/eventIndexer.ts <<'EOF'
import dotenv from "dotenv";
dotenv.config();
import { PrismaClient } from "@prisma/client";
import { provider } from "../services/eth";
import fs from "fs";
import path from "path";
import { ethers } from "ethers";

const prisma = new PrismaClient();

function loadAbi(name: string) {
  const p = path.join(process.cwd(), "contracts", "abis", name);
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

const contracts = [
  { name: "arenaPVP", address: process.env.ARENA_PVP_CONTRACT_ADDRESS!, abi: loadAbi("ChallengeManager.json") },
  { name: "arenaBattle", address: process.env.ARENA_BATTLE_CONTRACT_ADDRESS!, abi: loadAbi("Tournament.json") },
  { name: "arenaToken", address: process.env.ARNA_TOKEN_ADDRESS!, abi: loadAbi("ERC20.json") },
  { name: "champions", address: process.env.CHAMPION_CONTRACT_ADDRESS!, abi: loadAbi("Champion.json") },
  { name: "marketplace", address: process.env.MARKETPLACE_CONTRACT_ADDRESS!, abi: loadAbi("Marketplace.json") }
];

async function getCursor() {
  let cursor = await prisma.eventCursor.findUnique({ where: { id: 1 } });
  if (!cursor) {
    cursor = await prisma.eventCursor.create({ data: { id: 1, lastProcessedBlock: 0 } });
  }
  return cursor;
}

function buildTopics(abi: any[]) {
  const iface = new ethers.Interface(abi);
  const topics: Record<string, string> = {};
  for (const frag of abi) {
    if (frag.type === "event") {
      const topic = iface.getEventTopic(frag.name);
      topics[topic] = frag.name;
    }
  }
  return { iface, topics };
}

async function indexOnce() {
  const cursor = await getCursor();
  const fromBlock = cursor.lastProcessedBlock + 1;
  const latest = await provider.getBlockNumber();
  if (fromBlock > latest) {
    return latest;
  }

  console.log(\`Indexing from \${fromBlock} to \${latest}\`);
  for (const c of contracts) {
    const { iface, topics } = buildTopics(c.abi);
    try {
      const logs = await provider.getLogs({
        fromBlock,
        toBlock: latest,
        address: c.address
      });
      for (const log of logs) {
        try {
          const parsed = iface.parseLog(log);
          const eventName = parsed.name;
          const args: Record<string, any> = {};
          parsed.args.forEach((v: any, i: number) => {
            const key = parsed.eventFragment.inputs[i].name || i.toString();
            args[key] = v.toString ? v.toString() : v;
          });
          await prisma.onChainEvent.create({
            data: {
              contract: c.name,
              eventName,
              blockNumber: Number(log.blockNumber),
              txHash: log.transactionHash,
              parsed: args
            }
          });
          console.log(\`Indexed \${c.name}.\${eventName} tx=\${log.transactionHash}\`);
        } catch (e) {
          console.error("decode log error", e);
        }
      }
    } catch (e) {
      console.error("getLogs error for", c.address, e);
    }
  }

  await prisma.eventCursor.upsert({
    where: { id: 1 },
    update: { lastProcessedBlock: latest },
    create: { id: 1, lastProcessedBlock: latest }
  });

  return latest;
}

async function main() {
  console.log("Starting event indexer worker...");
  while (true) {
    try {
      await indexOnce();
      await new Promise((r) => setTimeout(r, 12_000));
    } catch (e) {
      console.error("Indexer loop error", e);
      await new Promise((r) => setTimeout(r, 10_000));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
EOF

cat > backend/src/routes/spin.ts <<'EOF'
import express from "express";
import { authMiddleware, AuthRequest } from "../middleware/auth";
import { PrismaClient } from "@prisma/client";
import { chooseSpinTier } from "../utils/rng";
import { signer, ethers } from "../services/eth";
import dotenv from "dotenv";

dotenv.config();
const router = express.Router();

router.post("/", authMiddleware, async (req: AuthRequest, res) => {
  const prisma: PrismaClient = req.app.get("prisma");
  if (!req.auth) return res.status(401).json({ error: "unauth" });
  const address = req.auth.address.toLowerCase();

  const user = await prisma.user.findUnique({ where: { address } });
  if (!user) return res.status(404).json({ error: "user not found" });

  const now = new Date();
  if (user.lastSpinAt) {
    const elapsed = (now.getTime() - user.lastSpinAt.getTime()) / 1000;
    if (elapsed < (user.cooldownSecs || 5)) {
      return res.status(429).json({ error: `cooldown active, wait ${Math.ceil((user.cooldownSecs || 5) - elapsed)}s` });
    }
  }

  const tier = chooseSpinTier();
  let grossRewardTokens = 0;
  if (tier === "common") grossRewardTokens = 10;
  else if (tier === "rare") grossRewardTokens = 50;
  else grossRewardTokens = 500;

  await prisma.spinLog.create({
    data: {
      userId: user.id,
      tier,
      reward: BigInt(grossRewardTokens)
    }
  });

  await prisma.user.update({ where: { id: user.id }, data: { lastSpinAt: new Date() } });

  try {
    const rewardAddress = process.env.GAME_REWARD_CONTRACT_ADDRESS!;
    if (!rewardAddress) {
      console.warn("GAME_REWARD_CONTRACT_ADDRESS missing - no onchain reward executed (dev mode)");
      return res.json({ tier, grossRewardTokens, message: "no onchain reward (dev)" });
    }
    const abi = [
      "function reward(address to, uint256 grossAmount) external",
    ];
    const contract = new ethers.Contract(rewardAddress, abi, signer);

    const grossAmount = ethers.parseUnits(String(grossRewardTokens), 18);
    const tx = await contract.reward(address, grossAmount);
    const rcpt = await tx.wait();
    await prisma.rewardLog.create({
      data: {
        userId: user.id,
        amount: BigInt(grossRewardTokens),
        txHash: rcpt.transactionHash
      }
    });

    return res.json({ tier, grossRewardTokens, txHash: rcpt.transactionHash });
  } catch (e: any) {
    console.error("reward error", e);
    return res.status(500).json({ error: "onchain reward failed", detail: String(e) });
  }
});

export default router;
EOF

cat > backend/src/routes/battle.ts <<'EOF'
import express from "express";
import { authMiddleware } from "../middleware/auth";
import { PrismaClient } from "@prisma/client";
import { signer, ethers } from "../services/eth";

const router = express.Router();

router.post("/", authMiddleware, async (req, res) => {
  const prisma: PrismaClient = req.app.get("prisma");
  if (!req.body) return res.status(400).json({ error: "body required" });
  const { mode } = req.body;
  const auth = (req as any).auth;
  if (!auth) return res.status(401).json({ error: "unauth" });
  const player = auth.address.toLowerCase();
  const seed = Math.floor(Math.random() * 100000);
  const playerRoll = (seed % 100) + 1 + (Math.floor(Math.random() * 20));
  const aiRoll = Math.floor(Math.random() * 100) + 1 + (Math.floor(Math.random() * 20));
  const winner = playerRoll >= aiRoll ? player : "AI_BOT";

  let rewardTokens = winner === player ? 100 : 0;
  await prisma.battleLog.create({
    data: {
      playerA: player,
      playerB: "AI_BOT",
      winner,
      reward: BigInt(rewardTokens)
    }
  });

  let txHash: string | null = null;
  if (winner === player && rewardTokens > 0) {
    try {
      const rewardAddress = process.env.GAME_REWARD_CONTRACT_ADDRESS!;
      const abi = ["function reward(address to, uint256 grossAmount) external"];
      const contract = new ethers.Contract(rewardAddress, abi, signer);
      const grossAmount = ethers.parseUnits(String(rewardTokens), 18);
      const tx = await contract.reward(player, grossAmount);
      const rcpt = await tx.wait();
      txHash = rcpt.transactionHash;
      await prisma.rewardLog.create({ data: { userId: (await prisma.user.findUnique({ where: { address: player } }))!.id, amount: BigInt(rewardTokens), txHash } });
    } catch (e) {
      console.error("battle reward failed", e);
    }
  }

  return res.json({ winner, rewardTokens, txHash });
});

export default router;
EOF

cat > backend/src/routes/marketplace.ts <<'EOF'
import express from "express";
import { authMiddleware } from "../middleware/auth";
import { marketplace } from "../services/contractClients";
import { PrismaClient } from "@prisma/client";
import { ethers } from "ethers";
import { champions } from "../services/contractClients";

const router = express.Router();

router.post("/list", authMiddleware, async (req: any, res) => {
  const prisma: PrismaClient = req.app.get("prisma");
  const auth = req.auth!;
  const { tokenId, price } = req.body;
  if (tokenId == null || price == null) return res.status(400).json({ error: "tokenId + price required" });

  try {
    const ownerOnChain = await champions.ownerOf(tokenId);
    if (ownerOnChain.toLowerCase() !== auth.address.toLowerCase()) {
      return res.status(403).json({ error: "not token owner" });
    }

    const priceWei = ethers.parseUnits(String(price), 18);
    const tx = await marketplace.listNFT(tokenId, priceWei);
    const receipt = await tx.wait();

    await prisma.marketplaceListing.create({
      data: {
        listingId: (await marketplace.listingCounter()).toNumber(),
        seller: auth.address,
        tokenId: Number(tokenId),
        price: priceWei.toString(),
        active: true,
      }
    });

    return res.json({ txHash: receipt.transactionHash });
  } catch (e: any) {
    console.error("listNFT error", e);
    return res.status(500).json({ error: String(e) });
  }
});

router.post("/buy", authMiddleware, async (req: any, res) => {
  const { listingId } = req.body;
  if (listingId == null) return res.status(400).json({ error: "listingId required" });
  try {
    const tx = await marketplace.buyNFT(listingId);
    const receipt = await tx.wait();
    return res.json({ txHash: receipt.transactionHash });
  } catch (e: any) {
    console.error("buyNFT error", e);
    return res.status(500).json({ error: String(e) });
  }
});

export default router;
EOF

cat > backend/src/routes/challenges.ts <<'EOF'
import express from "express";
import { authMiddleware } from "../middleware/auth";
import { arenaPVP, champions, arenaBattle } from "../services/contractClients";

const router = express.Router();

router.post("/create", authMiddleware, async (req: any, res) => {
  const { championId } = req.body;
  const auth = req.auth!;
  if (championId == null) return res.status(400).json({ error: "championId required" });

  try {
    const owner = await champions.ownerOf(championId);
    if (owner.toLowerCase() !== auth.address.toLowerCase()) {
      return res.status(403).json({ error: "not owner of champion" });
    }
    const tx = await arenaPVP.createChallenge(championId);
    const rcpt = await tx.wait();
    return res.json({ txHash: rcpt.transactionHash });
  } catch (e: any) {
    console.error("createChallenge error", e);
    return res.status(500).json({ error: String(e) });
  }
});

router.post("/accept", authMiddleware, async (req: any, res) => {
  const { challengeId, myChampionId } = req.body;
  const auth = req.auth!;
  if (challengeId == null || myChampionId == null) return res.status(400).json({ error: "challengeId + myChampionId required" });

  try {
    const owner = await champions.ownerOf(myChampionId);
    if (owner.toLowerCase() !== auth.address.toLowerCase()) {
      return res.status(403).json({ error: "not owner of champion" });
    }
    const tx = await arenaPVP.acceptChallenge(challengeId, myChampionId);
    const rcpt = await tx.wait();
    return res.json({ txHash: rcpt.transactionHash });
  } catch (e: any) {
    console.error("acceptChallenge error", e);
    return res.status(500).json({ error: String(e) });
  }
});

router.post("/enter", authMiddleware, async (req: any, res) => {
  try {
    const tx = await arenaBattle.enterBattle();
    const rcpt = await tx.wait();
    return res.json({ txHash: rcpt.transactionHash });
  } catch (e: any) {
    console.error("enterBattle error", e);
    return res.status(500).json({ error: String(e) });
  }
});

export default router;
EOF

cat > backend/src/routes/admin.ts <<'EOF'
import express from "express";
import { adminOnly, AuthRequest } from "../middleware/auth";
import { PrismaClient } from "@prisma/client";

const router = express.Router();

router.get("/events", adminOnly, async (req: AuthRequest, res) => {
  const prisma: PrismaClient = req.app.get("prisma");
  const events = await prisma.onChainEvent.findMany({ orderBy: { createdAt: "desc" }, take: 200 });
  res.json({ events });
});

router.post("/retry-tx", adminOnly, async (req: AuthRequest, res) => {
  const { txHash } = req.body;
  if (!txHash) return res.status(400).json({ error: "txHash required" });
  try {
    const provider = (await import("../services/eth")).provider;
    const tx = await provider.getTransaction(txHash);
    if (!tx) return res.status(404).json({ error: "tx not found on provider" });
    const receipt = await provider.getTransactionReceipt(txHash);
    return res.json({ tx, receipt });
  } catch (e: any) {
    console.error("retry-tx error", e);
    return res.status(500).json({ error: String(e) });
  }
});

export default router;
EOF

cat > backend/src/socket.ts <<'EOF'
import { Server as SocketIOServer } from "socket.io";
import { PrismaClient } from "@prisma/client";

const queue: { id: string; address: string }[] = [];

export function attachSocketHandlers(io: SocketIOServer, prisma: PrismaClient) {
  io.on("connection", (socket) => {
    console.log("socket connected", socket.id);
    socket.on("joinQueue", async (payload: { address: string }) => {
      const address = payload.address.toLowerCase();
      queue.push({ id: socket.id, address });
      if (queue.length >= 2) {
        const p1 = queue.shift()!;
        const p2 = queue.shift()!;
        const r = Math.random();
        const winner = r > 0.5 ? p1.address : p2.address;
        const reward = winner ? 100 : 0;
        await prisma.battleLog.create({ data: { playerA: p1.address, playerB: p2.address, winner, reward: BigInt(reward) }});
        io.to(p1.id).emit("matchResult", { opponent: p2.address, winner, reward });
        io.to(p2.id).emit("matchResult", { opponent: p1.address, winner, reward });
      } else {
        setTimeout(async () => {
          const idx = queue.findIndex(q => q.id === socket.id);
          if (idx >= 0) {
            queue.splice(idx, 1);
            const r = Math.random();
            const winner = r > 0.4 ? address : "AI_BOT";
            const reward = winner === address ? 50 : 0;
            await prisma.battleLog.create({ data: { playerA: address, playerB: "AI_BOT", winner, reward: BigInt(reward) }});
            socket.emit("matchResult", { opponent: "AI_BOT", winner, reward });
          }
        }, 5000);
      }
    });

    socket.on("disconnect", () => {
      const idx = queue.findIndex(q => q.id === socket.id);
      if (idx >= 0) queue.splice(idx, 1);
    });
  });
}
EOF

cat > backend/prisma/schema.prisma <<'EOF'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id            Int      @id @default(autoincrement())
  address       String   @unique
  nonce         String
  createdAt     DateTime @default(now())
  isAdmin       Boolean  @default(false)
  cooldownSecs  Int      @default(5)
  lastSpinAt    DateTime?
  displayName   String?
  score         Int      @default(0)
  spins         SpinLog[]
  battles       BattleLog[]
  rewards       RewardLog[]
}

model SpinLog {
  id        Int      @id @default(autoincrement())
  user      User     @relation(fields: [userId], references: [id])
  userId    Int
  tier      String
  reward    BigInt
  createdAt DateTime @default(now())
  meta      Json?
}

model BattleLog {
  id        Int      @id @default(autoincrement())
  playerA   String
  playerB   String
  winner    String
  reward    BigInt
  createdAt DateTime @default(now())
  meta      Json?
}

model RewardLog {
  id          Int      @id @default(autoincrement())
  user        User?    @relation(fields: [userId], references: [id])
  userId      Int?
  amount      BigInt
  txHash      String?
  createdAt   DateTime @default(now())
  detail      Json?
}

model Nonce {
  id        Int      @id @default(autoincrement())
  address   String   @unique
  nonce     String
  createdAt DateTime @default(now())
}

model MarketplaceListing {
  id         Int      @id @default(autoincrement())
  listingId  Int
  seller     String
  tokenId    Int
  price      String
  active     Boolean  @default(true)
  createdAt  DateTime @default(now())
  meta       Json?
}

model NFTTransfer {
  id          Int      @id @default(autoincrement())
  tokenId     Int
  fromAddress String
  toAddress   String
  txHash      String?
  createdAt   DateTime @default(now())
}

model OnChainEvent {
  id          Int      @id @default(autoincrement())
  contract    String
  eventName   String
  blockNumber Int
  txHash      String
  parsed      Json
  createdAt   DateTime @default(now())
}

model EventCursor {
  id               Int     @id
  lastProcessedBlock Int   @default(0)
}
EOF

echo "Creating shared package..."
mkdir -p shared
cat > shared/index.ts <<'EOF'
export type Tier = "common" | "rare" | "jackpot";

export interface User {
  address: string;
  displayName?: string;
  score?: number;
}
EOF

echo "Creating frontend package..."
mkdir -p frontend/pages frontend/public frontend/styles
cat > frontend/package.json <<'EOF'
{
  "name": "frontend",
  "private": true,
  "scripts": {
    "dev": "next dev -p 3000",
    "build": "next build",
    "start": "next start -p 3000"
  },
  "dependencies": {
    "next": "14.0.0",
    "react": "18.2.0",
    "react-dom": "18.2.0",
    "ethers": "^6.8.0",
    "framer-motion": "^10.12.1",
    "swr": "^2.2.0"
  }
}
EOF

cat > frontend/pages/_app.tsx <<'EOF'
import '../styles/globals.css';
import type { AppProps } from 'next/app';

export default function App({ Component, pageProps }: AppProps) {
  return <Component {...pageProps} />;
}
EOF

cat > frontend/pages/login.tsx <<'EOF'
import { useEffect, useState } from "react";
import { ethers } from "ethers";

export default function LoginPage() {
  const [address, setAddress] = useState<string | null>(null);
  const [token, setToken] = useState<string | null>(null);

  useEffect(() => {
    const t = localStorage.getItem("token");
    if (t) setToken(t);
  }, []);

  async function connectAndLogin() {
    if (!(window as any).ethereum) return alert("Install MetaMask");
    await (window as any).ethereum.request({ method: "eth_requestAccounts" });
    const provider = new ethers.BrowserProvider((window as any).ethereum);
    const signer = await provider.getSigner();
    const addr = await signer.getAddress();
    setAddress(addr);

    const r1 = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/auth/nonce?address=${addr}`);
    const { nonce } = await r1.json();
    const signature = await signer.signMessage(nonce);
    const r2 = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: addr, signature })
    });
    const data = await r2.json();
    if (data.token) {
      setToken(data.token);
      localStorage.setItem("token", data.token);
      alert("Logged in!");
    } else {
      alert("Login failed");
    }
  }

  return (
    <div style={{ padding: 24 }}>
      <h1>Arena - Wallet Login</h1>
      {token ? <div>Logged in</div> : <button onClick={connectAndLogin}>Connect Wallet & Login</button>}
    </div>
  );
}
EOF

cat > frontend/pages/spin.tsx <<'EOF'
import { useState } from "react";
export default function SpinPage() {
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<any>(null);

  async function doSpin() {
    setLoading(true);
    const token = localStorage.getItem("token");
    const res = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/spin`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }
    });
    const data = await res.json();
    setResult(data);
    setLoading(false);
  }

  return (
    <div style={{ padding: 24 }}>
      <h1>Spin Wheel</h1>
      <div style={{ marginTop: 20 }}>
        <button onClick={doSpin} disabled={loading}>
          {loading ? "Spinning..." : "Spin"}
        </button>
      </div>
      {result && <pre>{JSON.stringify(result, null, 2)}</pre>}
    </div>
  );
}
EOF

cat > frontend/styles/globals.css <<'EOF'
body { margin: 0; font-family: Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial; background: #020617; color: #eee; }
a { color: #8be9fd; }
EOF

echo "Creating admin package..."
mkdir -p admin/pages/api admin/pages admin/styles
cat > admin/package.json <<'EOF'
{
  "name": "admin",
  "private": true,
  "scripts": {
    "dev": "next dev -p 3001",
    "build": "next build",
    "start": "next start -p 3001"
  },
  "dependencies": {
    "next": "14.0.0",
    "react": "18.2.0",
    "react-dom": "18.2.0",
    "swr": "^2.2.0"
  }
}
EOF

cat > admin/pages/events.tsx <<'EOF'
import useSWR from "swr";
import React from "react";

const fetcher = (url: string) => fetch(url, { credentials: "include", headers: { "Content-Type": "application/json" } }).then(r => r.json());

export default function EventsPage() {
  const { data, error, mutate } = useSWR('/api/admin/events', fetcher, { refreshInterval: 5000 });

  if (error) return <div>Error loading events</div>;
  if (!data) return <div>Loading...</div>;

  return (
    <div style={{ padding: 24 }}>
      <h1>On-chain Events</h1>
      <button onClick={() => mutate()}>Refresh</button>
      <table style={{ width: "100%", marginTop: 12, borderCollapse: "collapse" }}>
        <thead>
          <tr><th>Time</th><th>Contract</th><th>Event</th><th>Block</th><th>Tx</th><th>Parsed</th></tr>
        </thead>
        <tbody>
          {data.events.map((e: any) => (
            <tr key={e.id} style={{ borderTop: "1px solid #222" }}>
              <td>{new Date(e.createdAt).toLocaleString()}</td>
              <td>{e.contract}</td>
              <td>{e.eventName}</td>
              <td>{e.blockNumber}</td>
              <td><a href={`https://sepolia.etherscan.io/tx/${e.txHash}`} target="_blank" rel="noreferrer">{e.txHash.slice(0, 12)}...</a></td>
              <td><pre style={{ whiteSpace: "pre-wrap" }}>{JSON.stringify(e.parsed)}</pre></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
EOF

cat > admin/pages/api/admin/events.ts <<'EOF'
import type { NextApiRequest, NextApiResponse } from "next";
export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  const backend = process.env.NEXT_PUBLIC_API_URL || "http://localhost:4000";
  const token = req.headers.authorization || "";
  const r = await fetch(`${backend}/admin/events`, { headers: { Authorization: token } });
  const json = await r.json();
  res.status(r.status).json(json);
}
EOF

echo "Zipping repository..."
cd ..
zip -r "$ZIPNAME" "$ROOT" > /dev/null

echo "Created $ZIPNAME in $(pwd)."
echo "Done. Unzip and follow README.md inside the project to install and run."

exit 0
