-----------------------------------------------------------------------------
-- |
-- Module      :  Swarm.TUI.Attr
-- Copyright   :  Brent Yorgey
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Rendering attributes (/i.e./ foreground and background colors,
-- styles, /etc./) used by the Swarm TUI.
--
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

module Swarm.TUI.Attr where

import           Brick
import           Brick.Forms
import qualified Graphics.Vty as V

-- | A mapping from the defined attribute names to TUI attributes.
swarmAttrMap :: AttrMap
swarmAttrMap = attrMap V.defAttr

  -- World rendering attributes
  [ (robotAttr,     fg V.white `V.withStyle` V.bold)
  , (entityAttr,    fg V.white)
  , (plantAttr,     fg V.green)
  , (rockAttr,      fg (V.rgbColor @Int 80 80 80))
  , (woodAttr,      fg (V.rgbColor @Int 139 69 19))
  , (flowerAttr,    fg (V.rgbColor @Int 200 0 200))
  , (snowAttr,      fg V.white)
  , (deviceAttr,    fg V.yellow `V.withStyle` V.bold)

  -- Terrain attributes
  , (dirtAttr,      fg (V.rgbColor @Int 165 42 42))
  , (grassAttr,     fg (V.rgbColor @Int 0 32 0)) -- dark green
  , (stoneAttr,     fg (V.rgbColor @Int 32 32 32))
  , (waterAttr,     V.white `on` V.blue)
  , (iceAttr,       bg V.white)

  -- UI rendering attributes
  , (highlightAttr, fg V.cyan)
  , (invalidFormInputAttr, fg V.red)
  , (focusedFormInputAttr, V.defAttr)

  -- Default attribute
  , (defAttr, V.defAttr)
  ]

-- | Some defined attribute names used in the Swarm TUI.
robotAttr, entityAttr, plantAttr, flowerAttr, snowAttr, rockAttr, baseAttr,
  woodAttr, deviceAttr,
  dirtAttr, grassAttr, stoneAttr, waterAttr, iceAttr,
  highlightAttr, defAttr :: AttrName
dirtAttr      = "dirtAttr"
grassAttr     = "grassAttr"
stoneAttr     = "stoneAttr"
waterAttr     = "waterAttr"
iceAttr       = "iceAttr"
robotAttr     = "robotAttr"
entityAttr    = "entityAttr"
plantAttr     = "plantAttr"
flowerAttr    = "flowerAttr"
snowAttr      = "snowAttr"
rockAttr      = "rockAttr"
woodAttr      = "woodAttr"
baseAttr      = "baseAttr"
deviceAttr    = "deviceAttr"
highlightAttr = "highlightAttr"
defAttr       = "defAttr"
