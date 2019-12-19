{-# LANGUAGE
    FlexibleContexts
  , GADTs
  , OverloadedStrings
  , ScopedTypeVariables
  , TypeApplications
#-}

module Squeal.PostgreSQL.PQ.Result
  ( Result (..)
  , getRow
  , firstRow
  , getRows
  , nextRow
  , ntuples
  , nfields
  , resultStatus
  , okResult
  , resultErrorMessage
  , resultErrorCode
  , LibPQ.ExecStatus (..)
  ) where

import Control.Exception (throw)
import Control.Monad (when)
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import Data.Text (Text, pack)
import Data.Traversable (for)

import qualified Database.PostgreSQL.LibPQ as LibPQ
import qualified Generics.SOP as SOP

import Squeal.PostgreSQL.PQ.Decode
import Squeal.PostgreSQL.PQ.Exception

data Result y where
  Result
    :: SOP.SListI row
    => DecodeRow row y
    -> LibPQ.Result
    -> Result y
instance Functor Result where
  fmap f (Result decode result) = Result (fmap f decode) result

-- | Get a row corresponding to a given row number from a `LibPQ.Result`,
-- throwing an exception if the row number is out of bounds.
getRow :: MonadIO io => LibPQ.Row -> Result y -> io y
getRow r (Result decode result) = liftIO $ do
  numRows <- LibPQ.ntuples result
  numCols <- LibPQ.nfields result
  when (numRows < r) $ throw $ ResultException $
    "getRow: expected at least " <> pack (show r) <> "rows but only saw "
    <> pack (show numRows)
  row' <- traverse (LibPQ.getvalue result r) [0 .. numCols - 1]
  case SOP.fromList row' of
    Nothing -> throw $ ResultException "getRow: found unexpected length"
    Just row -> case execDecodeRow decode row of
      Left parseError -> throw $ ParseException $ "getRow: " <> parseError
      Right y -> return y

-- | Intended to be used for unfolding in streaming libraries, `nextRow`
-- takes a total number of rows (which can be found with `ntuples`)
-- and a `LibPQ.Result` and given a row number if it's too large returns `Nothing`,
-- otherwise returning the row along with the next row number.
nextRow
  :: MonadIO io
  => LibPQ.Row -- ^ total number of rows
  -> Result y -- ^ result
  -> LibPQ.Row -- ^ row number
  -> io (Maybe (LibPQ.Row, y))
nextRow total (Result decode result) r
  = liftIO $ if r >= total then return Nothing else do
    numCols <- LibPQ.nfields result
    row' <- traverse (LibPQ.getvalue result r) [0 .. numCols - 1]
    case SOP.fromList row' of
      Nothing -> throw $ ResultException "nextRow: found unexpected length"
      Just row -> case execDecodeRow decode row of
        Left parseError -> throw $ ParseException $ "nextRow: " <> parseError
        Right y -> return $ Just (r+1, y)

-- | Get all rows from a `LibPQ.Result`.
getRows :: MonadIO io => Result y -> io [y]
getRows (Result decode result) = liftIO $ do
  numCols <- LibPQ.nfields result
  numRows <- LibPQ.ntuples result
  for [0 .. numRows - 1] $ \ r -> do
    row' <- traverse (LibPQ.getvalue result r) [0 .. numCols - 1]
    case SOP.fromList row' of
      Nothing -> throw $ ResultException "getRows: found unexpected length"
      Just row -> case execDecodeRow decode row of
        Left parseError -> throw $ ParseException $ "getRows: " <> parseError
        Right y -> return y

-- | Get the first row if possible from a `LibPQ.Result`.
firstRow :: MonadIO io => Result y -> io (Maybe y)
firstRow (Result decode result) = liftIO $ do
  numRows <- LibPQ.ntuples result
  numCols <- LibPQ.nfields result
  if numRows <= 0 then return Nothing else do
    row' <- traverse (LibPQ.getvalue result 0) [0 .. numCols - 1]
    case SOP.fromList row' of
      Nothing -> throw $ ResultException "firstRow: found unexpected length"
      Just row -> case execDecodeRow decode row of
        Left parseError -> throw $ ParseException $ "firstRow: " <> parseError
        Right y -> return $ Just y

-- | Lifts actions on results from @LibPQ@.
liftResult
  :: MonadIO io
  => (LibPQ.Result -> IO x)
  -> Result y -> io x
liftResult f (Result _ result) = liftIO $ f result

-- | Returns the number of rows (tuples) in the query result.
ntuples :: MonadIO io => Result y -> io LibPQ.Row
ntuples = liftResult LibPQ.ntuples

-- | Returns the number of columns (fields) in the query result.
nfields :: MonadIO io => Result y -> io LibPQ.Column
nfields = liftResult LibPQ.nfields

-- | Returns the result status of the command.
resultStatus :: MonadIO io => Result y -> io LibPQ.ExecStatus
resultStatus = liftResult LibPQ.resultStatus

okResult_ :: MonadIO io => LibPQ.Result -> io ()
okResult_ result = liftIO $ do
  status <- LibPQ.resultStatus result
  case status of
    LibPQ.CommandOk -> return ()
    LibPQ.TuplesOk -> return ()
    _ -> do
      stateCode <- LibPQ.resultErrorField result LibPQ.DiagSqlstate
      msg <- LibPQ.resultErrorMessage result
      throw . PQException $ PQState status stateCode msg

-- | Check if a `LibPQ.Result`'s status is either `LibPQ.CommandOk`
-- or `LibPQ.TuplesOk` otherwise `throw` a `PQException`.
okResult :: MonadIO io => SOP.K LibPQ.Result row -> io ()
okResult = okResult_ . SOP.unK

-- | Returns the error message most recently generated by an operation
-- on the connection.
resultErrorMessage
  :: MonadIO io => Result y -> io (Maybe ByteString)
resultErrorMessage = liftResult LibPQ.resultErrorMessage

-- | Returns the error code most recently generated by an operation
-- on the connection.
--
-- https://www.postgresql.org/docs/current/static/errcodes-appendix.html
resultErrorCode
  :: MonadIO io
  => Result y
  -> io (Maybe ByteString)
resultErrorCode = liftResult (flip LibPQ.resultErrorField LibPQ.DiagSqlstate)

execDecodeRow
  :: DecodeRow row y
  -> SOP.NP (SOP.K (Maybe ByteString)) row
  -> Either Text y
execDecodeRow decode = runDecodeRow decode
