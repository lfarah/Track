//
//  MemoryCache.swift
//  Demo
//
//  Created by 马权 on 5/17/16.
//  Copyright © 2016 马权. All rights reserved.
//

/*
    MemoryCache
 
    thread safe = concurrent + semaphore lock
 
    sync
    thread safe write = write + semaphore lock
    thread safe read = read + semaphore lokc
    
    async
    thread safe write = async concurrent queue + thread safe sync write
    thread safe read = async concurrent queue + thread safe sync read
 
 */

import Foundation
import UIKit

class MemoryCacheObject: LRUObjectBase {
    var key: String = ""
    var cost: UInt = 0
    var age: NSTimeInterval = CACurrentMediaTime()
    var value: AnyObject
    init(key: String, value: AnyObject, cost: UInt = 0) {
        self.key = key
        self.value = value
        self.cost = cost
    }
}

func == (lhs: MemoryCacheObject, rhs: MemoryCacheObject) -> Bool {
    return lhs.key == rhs.key
}

public typealias MemoryCacheAsyncCompletion = (cache: MemoryCache?, key: String?, object: AnyObject?) -> Void

public class MemoryCache {
    
    public var totalCount: UInt {
        get {
            lock()
            let count = _cache.count
            unlock()
            return count
        }
    }
    
    public var totalCost: UInt {
        get {
            lock()
            let cost = _cache.cost
            unlock()
            return cost
        }
    }
    
    private var _countLimit: UInt = UInt.max
    public var countLimit: UInt {
        set {
            lock()
            _costLimit = newValue
            _unsafeTrimToCount(newValue)
            unlock()
        }
        get {
            lock()
            let countLimit = _countLimit
            unlock()
            return countLimit
        }
    }
    
    private var _costLimit: UInt = UInt.max
    public var costLimit: UInt {
        set {
            lock()
            _costLimit = newValue
            _unsafeTrimToCost(newValue)
            unlock()
        }
        get {
            lock()
            let costLimit = _costLimit
            unlock()
            return costLimit
        }
    }
    
    private var _ageLimit: NSTimeInterval = DBL_MAX
    public var ageLimit: NSTimeInterval {
        set {
            lock()
            _ageLimit = newValue
            _unsafeTrimToAge(newValue)
            unlock()
        }
        get {
            lock()
            let ageLimit = _ageLimit
            unlock()
            return ageLimit
        }
    }
    
    private let _cache: LRU = LRU<MemoryCacheObject>()
    
    private let _queue: dispatch_queue_t = dispatch_queue_create(TrackCachePrefix + String(MemoryCache), DISPATCH_QUEUE_CONCURRENT)
    
    private let _semaphoreLock: dispatch_semaphore_t = dispatch_semaphore_create(1)
    
    private var _shouldRemoveAllObjectWhenMemoryWarning: Bool
    
    //  MARK: 
    //  MARK: Public
    public static let shareInstance = MemoryCache()
    
    public init () {
        _shouldRemoveAllObjectWhenMemoryWarning = true
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MemoryCache._didReceiveMemoryWarningNotification), name: UIApplicationDidReceiveMemoryWarningNotification, object: nil)
    }

    //  MARK: Async
    /**
     Async method to operate cache
     */
    public func set(object object: AnyObject, forKey key: String, cost: UInt = 0, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: key, object: object); return }
            strongSelf.set(object: object, forKey: key, cost: cost)
            completion?(cache: strongSelf, key: key, object: object)
        }
    }
    
    public func object(forKey key: String, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: key, object: nil); return }
            let object = strongSelf.object(forKey: key)
            completion?(cache: strongSelf, key: key, object: object)
        }
    }
    
    public func removeObject(forKey key: String, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: key, object: nil); return }
            strongSelf.removeObject(forKey: key)
            completion?(cache: strongSelf, key: key, object: nil)
        }
    }
    
    public func removeAllObjects(completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.removeAllObjects()
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    public func trimToCount(count: UInt, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.trimToCount(count)
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    public func trimToCost(cost: UInt, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.trimToCost(cost)
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    public func trimToAge(age: NSTimeInterval, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.trimToAge(age)
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    //  MARK: Sync
    /**
     Sync method to operate cache
     */
    public func set(object object: AnyObject, forKey key: String, cost: UInt = 0) {
        lock()
        _cache.set(object: MemoryCacheObject(key: key, value: object, cost: cost), forKey: key)
        if _cache.cost > _costLimit {
            _unsafeTrimToCost(_costLimit)
        }
        if _cache.count > _countLimit {
            _unsafeTrimToCount(_countLimit)
        }
        unlock()
    }
    
    public func object(forKey key: String) -> AnyObject? {
        var object: MemoryCacheObject? = nil
        lock()
        object = _cache.object(forKey: key)
        object?.age = CACurrentMediaTime()
        unlock()
        return object?.value
    }
    
    public func removeObject(forKey key: String) {
        lock()
        _cache.removeObject(forKey:key)
        unlock()
    }
    
    public func removeAllObjects() {
        lock()
        _cache.removeAllObjects()
        unlock()
    }
    
    public func trimToCount(count: UInt) {
        lock()
        _unsafeTrimToCount(count)
        unlock()
    }

    public func trimToCost(cost: UInt) {
        lock()
        _unsafeTrimToCost(cost)
        unlock()
    }

    public func trimToAge(age: NSTimeInterval) {
        lock()
        _unsafeTrimToAge(age)
        unlock()
    }

    public subscript(key: String) -> AnyObject? {
        get {
            return object(forKey: key)
        }
        set {
            if let newValue = newValue {
                set(object: newValue, forKey: key)
            } else {
                removeObject(forKey: key)
            }
        }
    }

    //  MARK:
    //  MARK: Private
    @objc private func _didReceiveMemoryWarningNotification() {
        if _shouldRemoveAllObjectWhenMemoryWarning {
            removeAllObjects(nil)
        }
    }
    
    private func _unsafeTrimToCount(count: UInt) {
        if _cache.count <= count {
            return
        }
        if count == 0 {
            _cache.removeAllObjects()
        }
        var newTailObject: MemoryCacheObject? = _cache.lastObject()
        while (newTailObject != nil && _cache.count > count) {
            _cache.removeLastObject()
            newTailObject = _cache.lastObject()
        }
    }
 
    private func _unsafeTrimToCost(cost: UInt) {
        if _cache.cost <= cost {
            return
        }
        if cost == 0 {
            _cache.removeAllObjects()
            return
        }
        var newTailObject: MemoryCacheObject? = _cache.lastObject()
        while (newTailObject != nil && _cache.cost > cost) {
            _cache.removeLastObject()
            newTailObject = _cache.lastObject()
        }
    }
    
    private func _unsafeTrimToAge(age: NSTimeInterval) {
        if _ageLimit <= age {
            return
        }
        if age == 0 {
            _cache.removeAllObjects()
        }
        var newTailObject: MemoryCacheObject? = _cache.lastObject()
        while (newTailObject != nil && newTailObject?.age < age) {
            _cache.removeLastObject()
            newTailObject = _cache.lastObject()
        }
    }
}

//  MARK: ThreadSafeProtocol
private extension MemoryCache {
    func lock() {
        dispatch_semaphore_wait(_semaphoreLock, DISPATCH_TIME_FOREVER)
    }
    
    func unlock() {
        dispatch_semaphore_signal(_semaphoreLock)
    }
}