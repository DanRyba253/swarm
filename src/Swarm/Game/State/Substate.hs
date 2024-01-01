{-# LANGUAGE TemplateHaskell #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Subrecord definitions that belong to 'Swarm.Game.State.GameState'
module Swarm.Game.State.Substate (
  GameStateConfig (..),
  REPLStatus (..),
  WinStatus (..),
  WinCondition (..),
  ObjectiveCompletion (..),
  _NoWinCondition,
  _WinConditions,
  Announcement (..),
  RunStatus (..),
  Seed,
  Step (..),
  SingleStep (..),

  -- ** GameState fields

  -- *** Randomness state
  Randomness,
  initRandomness,
  seed,
  randGen,

  -- *** Temporal state
  TemporalState,
  initTemporalState,
  gameStep,
  runStatus,
  ticks,
  robotStepsPerTick,
  paused,

  -- *** Recipes
  Recipes,
  initRecipeMaps,
  recipesOut,
  recipesIn,
  recipesCat,

  -- *** Messages
  Messages,
  initMessages,
  messageQueue,
  lastSeenMessageTime,
  announcementQueue,

  -- *** Controls
  GameControls,
  initGameControls,
  initiallyRunCode,
  replStatus,
  replNextValueIndex,
  inputHandler,

  -- *** Discovery
  Discovery,
  initDiscovery,
  allDiscoveredEntities,
  availableRecipes,
  availableCommands,
  knownEntities,
  gameAchievements,
  structureRecognition,
  tagMembers,

  -- *** Landscape
  Landscape,
  initLandscape,
  worldNavigation,
  multiWorld,
  worldScrollable,
  entityMap,

  -- ** Notifications
  Notifications (..),
  notificationsCount,
  notificationsContent,

  -- ** Utilities
  defaultRobotStepsPerTick,
  replActiveType,
  replWorking,
  toggleRunStatus,
) where

import Control.Lens hiding (Const, use, uses, view, (%=), (+=), (.=), (<+=), (<<.=))
import Data.Aeson (FromJSON, ToJSON)
import Data.IntMap (IntMap)
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import Data.Map qualified as M
import Data.Sequence (Seq)
import Data.Set qualified as S
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant.Docs (ToSample)
import Servant.Docs qualified as SD
import Swarm.Game.Achievement.Attainment
import Swarm.Game.Achievement.Definitions
import Swarm.Game.CESK (TickNumber (..))
import Swarm.Game.Entity
import Swarm.Game.Location
import Swarm.Game.Recipe (
  Recipe,
  catRecipeMap,
  inRecipeMap,
  outRecipeMap,
 )
import Swarm.Game.Robot
import Swarm.Game.Scenario.Objective
import Swarm.Game.Scenario.Topography.Navigation.Portal (Navigation (..))
import Swarm.Game.Scenario.Topography.Structure.Recognition
import Swarm.Game.Scenario.Topography.Structure.Recognition.Registry (emptyFoundStructures)
import Swarm.Game.Scenario.Topography.Structure.Recognition.Type (RecognizerAutomatons (..))
import Swarm.Game.State.Config
import Swarm.Game.Universe as U
import Swarm.Game.World qualified as W
import Swarm.Game.World.Gen (Seed)
import Swarm.Language.Pipeline (ProcessedTerm)
import Swarm.Language.Syntax (Const)
import Swarm.Language.Typed (Typed (Typed))
import Swarm.Language.Types (Polytype)
import Swarm.Language.Value (Value)
import Swarm.Log
import Swarm.Util.Lens (makeLensesNoSigs)
import System.Random (StdGen, mkStdGen)

-- * Subsidiary data types

-- | A data type to represent the current status of the REPL.
data REPLStatus
  = -- | The REPL is not doing anything actively at the moment.
    --   We persist the last value and its type though.
    --
    --   INVARIANT: the 'Value' stored here is not a 'Swarm.Language.Value.VResult'.
    REPLDone (Maybe (Typed Value))
  | -- | A command entered at the REPL is currently being run.  The
    --   'Polytype' represents the type of the expression that was
    --   entered.  The @Maybe Value@ starts out as 'Nothing' and gets
    --   filled in with a result once the command completes.
    REPLWorking (Typed (Maybe Value))
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data WinStatus
  = -- | There are one or more objectives remaining that the player
    -- has not yet accomplished.
    Ongoing
  | -- | The player has won.
    -- The boolean indicates whether they have
    -- already been congratulated.
    Won Bool
  | -- | The player has completed certain "goals" that preclude
    -- (via negative prerequisites) the completion of all of the
    -- required goals.
    -- The boolean indicates whether they have
    -- already been informed.
    Unwinnable Bool
  deriving (Show, Generic, FromJSON, ToJSON)

data WinCondition
  = -- | There is no winning condition.
    NoWinCondition
  | -- | NOTE: It is possible to continue to achieve "optional" objectives
    -- even after the game has been won (or deemed unwinnable).
    WinConditions WinStatus ObjectiveCompletion
  deriving (Show, Generic, FromJSON, ToJSON)

makePrisms ''WinCondition

instance ToSample WinCondition where
  toSamples _ =
    SD.samples
      [ NoWinCondition
      -- TODO: #1552 add simple objective sample
      ]

-- | A data type to keep track of the pause mode.
data RunStatus
  = -- | The game is running.
    Running
  | -- | The user paused the game, and it should stay pause after visiting the help.
    ManualPause
  | -- | The game got paused while visiting the help,
    --   and it should unpause after returning back to the game.
    AutoPause
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- | Switch (auto or manually) paused game to running and running to manually paused.
--
--   Note that this function is not safe to use in the app directly, because the UI
--   also tracks time between ticks---use 'Swarm.TUI.Controller.safeTogglePause' instead.
toggleRunStatus :: RunStatus -> RunStatus
toggleRunStatus s = if s == Running then ManualPause else Running

-- | A data type to keep track of some kind of log or sequence, with
--   an index to remember which ones are "new" and which ones have
--   "already been seen".
data Notifications a = Notifications
  { _notificationsCount :: Int
  , _notificationsContent :: [a]
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

instance Semigroup (Notifications a) where
  Notifications count1 xs1 <> Notifications count2 xs2 = Notifications (count1 + count2) (xs1 <> xs2)

instance Monoid (Notifications a) where
  mempty = Notifications 0 []

makeLenses ''Notifications

data Recipes = Recipes
  { _recipesOut :: IntMap [Recipe Entity]
  , _recipesIn :: IntMap [Recipe Entity]
  , _recipesCat :: IntMap [Recipe Entity]
  }

makeLensesNoSigs ''Recipes

-- | All recipes the game knows about, indexed by outputs.
recipesOut :: Lens' Recipes (IntMap [Recipe Entity])

-- | All recipes the game knows about, indexed by inputs.
recipesIn :: Lens' Recipes (IntMap [Recipe Entity])

-- | All recipes the game knows about, indexed by requirement/catalyst.
recipesCat :: Lens' Recipes (IntMap [Recipe Entity])

data Messages = Messages
  { _messageQueue :: Seq LogEntry
  , _lastSeenMessageTime :: TickNumber
  , _announcementQueue :: Seq Announcement
  }

makeLensesNoSigs ''Messages

-- | A queue of global messages.
--
-- Note that we put the newest entry to the right.
messageQueue :: Lens' Messages (Seq LogEntry)

-- | Last time message queue has been viewed (used for notification).
lastSeenMessageTime :: Lens' Messages TickNumber

-- | A queue of global announcements.
-- Note that this is distinct from the 'messageQueue',
-- which is for messages emitted by robots.
--
-- Note that we put the newest entry to the right.
announcementQueue :: Lens' Messages (Seq Announcement)

-- | Type for remembering which robots will be run next in a robot step mode.
--
-- Once some robots have run, we need to store 'RID' to know which ones should go next.
-- At 'SBefore' no robots were run yet, so it is safe to transition to and from 'WorldTick'.
--
-- @
--                     tick
--     ┌────────────────────────────────────┐
--     │                                    │
--     │               step                 │
--     │              ┌────┐                │
--     ▼              ▼    │                │
-- ┌───────┐ step  ┌───────┴───┐ step  ┌────┴─────┐
-- │SBefore├──────►│SSingle RID├──────►│SAfter RID│
-- └──┬────┘       └───────────┘       └────┬─────┘
--    │ ▲ player        ▲                   │
--    ▼ │ switch        └───────────────────┘
-- ┌────┴────┐             view RID > oldRID
-- │WorldTick│
-- └─────────┘
-- @
data SingleStep
  = -- | Run the robots from the beginning until the focused robot (noninclusive).
    SBefore
  | -- | Run a single step of the focused robot.
    SSingle RID
  | -- | Run robots after the (previously) focused robot and finish the tick.
    SAfter RID

-- | Game step mode - we use the single step mode when debugging robot 'CESK' machine.
data Step = WorldTick | RobotStep SingleStep

data TemporalState = TemporalState
  { _gameStep :: Step
  , _runStatus :: RunStatus
  , _ticks :: TickNumber
  , _robotStepsPerTick :: Int
  }

makeLensesNoSigs ''TemporalState

-- | How to step the game: 'WorldTick' or 'RobotStep' for debugging the 'CESK' machine.
gameStep :: Lens' TemporalState Step

-- | The current 'RunStatus'.
runStatus :: Lens' TemporalState RunStatus

-- | Whether the game is currently paused.
paused :: Getter TemporalState Bool
paused = to (\s -> s ^. runStatus /= Running)

-- | The number of ticks elapsed since the game started.
ticks :: Lens' TemporalState TickNumber

-- | The maximum number of CESK machine steps a robot may take during
--   a single tick.
robotStepsPerTick :: Lens' TemporalState Int

data GameControls = GameControls
  { _replStatus :: REPLStatus
  , _replNextValueIndex :: Integer
  , _inputHandler :: Maybe (Text, Value)
  , _initiallyRunCode :: Maybe ProcessedTerm
  }

makeLensesNoSigs ''GameControls

-- | The current status of the REPL.
replStatus :: Lens' GameControls REPLStatus

-- | The index of the next @it{index}@ value
replNextValueIndex :: Lens' GameControls Integer

-- | The currently installed input handler and hint text.
inputHandler :: Lens' GameControls (Maybe (Text, Value))

-- | Code that is run upon scenario start, before any
-- REPL interaction.
initiallyRunCode :: Lens' GameControls (Maybe ProcessedTerm)

data Discovery = Discovery
  { _allDiscoveredEntities :: Inventory
  , _availableRecipes :: Notifications (Recipe Entity)
  , _availableCommands :: Notifications Const
  , _knownEntities :: S.Set EntityName
  , _gameAchievements :: Map GameplayAchievement Attainment
  , _structureRecognition :: StructureRecognizer
  , _tagMembers :: Map Text (NonEmpty EntityName)
  }

makeLensesNoSigs ''Discovery

-- | The list of entities that have been discovered.
allDiscoveredEntities :: Lens' Discovery Inventory

-- | The list of available recipes.
availableRecipes :: Lens' Discovery (Notifications (Recipe Entity))

-- | The list of available commands.
availableCommands :: Lens' Discovery (Notifications Const)

-- | The names of entities that should be considered \"known\", that is,
--   robots know what they are without having to scan them.
knownEntities :: Lens' Discovery (S.Set EntityName)

-- | Map of in-game achievements that were obtained
gameAchievements :: Lens' Discovery (Map GameplayAchievement Attainment)

-- | Recognizer for robot-constructed structures
structureRecognition :: Lens' Discovery StructureRecognizer

-- | Map from tags to entities that possess that tag
tagMembers :: Lens' Discovery (Map Text (NonEmpty EntityName))

data Landscape = Landscape
  { _worldNavigation :: Navigation (M.Map SubworldName) Location
  , _multiWorld :: W.MultiWorld Int Entity
  , _entityMap :: EntityMap
  , _worldScrollable :: Bool
  }

makeLensesNoSigs ''Landscape

-- | Includes a 'Map' of named locations and an
-- "edge list" (graph) that maps portal entrances to exits
worldNavigation :: Lens' Landscape (Navigation (M.Map SubworldName) Location)

-- | The current state of the world (terrain and entities only; robots
--   are stored in the 'robotMap').  'Int' is used instead of
--   'TerrainType' because we need to be able to store terrain values in
--   unboxed tile arrays.
multiWorld :: Lens' Landscape (W.MultiWorld Int Entity)

-- | The catalog of all entities that the game knows about.
entityMap :: Lens' Landscape EntityMap

-- | Whether the world map is supposed to be scrollable or not.
worldScrollable :: Lens' Landscape Bool

data Randomness = Randomness
  { _seed :: Seed
  , _randGen :: StdGen
  }

makeLensesNoSigs ''Randomness

-- | The initial seed that was used for the random number generator,
--   and world generation.
seed :: Lens' Randomness Seed

-- | Pseudorandom generator initialized at start.
randGen :: Lens' Randomness StdGen

-- * Utilities

-- | Whether the repl is currently working.
replWorking :: Getter GameControls Bool
replWorking = to (\s -> matchesWorking $ s ^. replStatus)
 where
  matchesWorking (REPLDone _) = False
  matchesWorking (REPLWorking _) = True

-- | Either the type of the command being executed, or of the last command
replActiveType :: Getter REPLStatus (Maybe Polytype)
replActiveType = to getter
 where
  getter (REPLDone (Just (Typed _ typ _))) = Just typ
  getter (REPLWorking (Typed _ typ _)) = Just typ
  getter _ = Nothing

-- | By default, robots may make a maximum of 100 CESK machine steps
--   during one game tick.
defaultRobotStepsPerTick :: Int
defaultRobotStepsPerTick = 100

-- * Record initialization

initTemporalState :: TemporalState
initTemporalState =
  TemporalState
    { _gameStep = WorldTick
    , _runStatus = Running
    , _ticks = TickNumber 0
    , _robotStepsPerTick = defaultRobotStepsPerTick
    }

initGameControls :: GameControls
initGameControls =
  GameControls
    { _replStatus = REPLDone Nothing
    , _replNextValueIndex = 0
    , _inputHandler = Nothing
    , _initiallyRunCode = Nothing
    }

initMessages :: Messages
initMessages =
  Messages
    { _messageQueue = Empty
    , _lastSeenMessageTime = TickNumber (-1)
    , _announcementQueue = mempty
    }

initLandscape :: GameStateConfig -> Landscape
initLandscape gsc =
  Landscape
    { _worldNavigation = Navigation mempty mempty
    , _multiWorld = mempty
    , _entityMap = initEntities gsc
    , _worldScrollable = True
    }

initDiscovery :: Discovery
initDiscovery =
  Discovery
    { _availableRecipes = mempty
    , _availableCommands = mempty
    , _allDiscoveredEntities = empty
    , _knownEntities = mempty
    , -- This does not need to be initialized with anything,
      -- since the master list of achievements is stored in UIState
      _gameAchievements = mempty
    , _structureRecognition = StructureRecognizer (RecognizerAutomatons mempty mempty) emptyFoundStructures []
    , _tagMembers = mempty
    }

initRandomness :: Randomness
initRandomness =
  Randomness
    { _seed = 0
    , _randGen = mkStdGen 0
    }

initRecipeMaps :: GameStateConfig -> Recipes
initRecipeMaps gsc =
  Recipes
    { _recipesOut = outRecipeMap (initRecipes gsc)
    , _recipesIn = inRecipeMap (initRecipes gsc)
    , _recipesCat = catRecipeMap (initRecipes gsc)
    }