#pragma once

#include "platform/location.hpp"

#include "base/exception.hpp"
#include "base/macros.hpp"

#include <fstream>
#include <functional>
#include <string>
#include <vector>

class GpsTrackStorage final
{
public:
  DECLARE_EXCEPTION(OpenException, RootException);
  DECLARE_EXCEPTION(WriteException, RootException);
  DECLARE_EXCEPTION(ReadException, RootException);

  using TItem = location::GpsInfo;

  /// Opens storage with track data.
  /// @param filePath - path to the file on disk
  /// @exception OpenException if seek fails.
  GpsTrackStorage(std::string const & filePath);

  /// Appends new point to the storage
  /// @param items - collection of gps track points.
  /// @exceptions WriteException if write fails or ReadException if read fails.
  void Append(std::vector<TItem> const & items);

  /// Removes all data from the storage
  /// @exceptions WriteException if write fails.
  void Clear();

  /// Reads the storage and calls functor for each item
  /// @param fn - callable function, return true to stop ForEach
  /// @exceptions ReadException if read fails.
  void ForEach(std::function<bool(TItem const & item)> const & fn);

  /// Read a completed raw archive without opening it for writing or repairing it.
  /// Rejects unknown versions, partial records, invalid source tags and oversized files.
  static std::vector<TItem> ReadSnapshot(std::string const & filePath, size_t maximumBytes = 64 * 1024 * 1024);

private:
  DISALLOW_COPY_AND_MOVE(GpsTrackStorage);

  size_t GetFirstItemIndex() const;

  std::string const m_filePath;
  std::fstream m_stream;
  size_t m_itemCount;
};
